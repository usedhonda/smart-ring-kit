import Foundation
import XCTest
@testable import SmartRingKit

final class NativeFatigueTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_704_067_200)
    private func time(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }
    private func sample(_ seconds: Double, _ hr: Double, delay: Double = 0) -> RingFatigueSample {
        RingFatigueSample(measuredAt: time(seconds), availableAt: time(seconds + delay), values: ["heartRateBPM": hr])
    }
    private func anchor(_ seconds: Double, _ value: UInt8, delay: Double = 0) -> RingNativeFatigueAnchor {
        RingNativeFatigueAnchor(measuredAt: time(seconds), availableAt: time(seconds + delay), value: value)
    }
    private var samples: [RingFatigueSample] { (1...4).map { sample(Double($0 - 5) * 3600, Double($0)) } }
    private var anchors: [RingNativeFatigueAnchor] { (1...4).map { anchor(Double($0 - 5) * 3600, UInt8($0 * 10)) } }
    private func model(_ correction: RingFatigueCorrection) throws -> RingFatigueEstimator {
        try RingFatigueEstimator(samples: samples, anchors: anchors, before: base, asOf: base,
            configuration: RingFatigueConfiguration(correction: correction, minimumTrainingSamples: 4))
    }

    func testNewAnchorCorrectsUsingSameModelAndFutureAnchorCannotLeak() throws {
        let m = try model(.fullResidual)
        let s = samples + [sample(60, 2), sample(660, 3)]
        let a = anchors + [anchor(60, 30), anchor(1200, 200)]
        let r = try m.estimate(samples: s, anchors: a, at: time(660), asOf: time(660))
        XCTAssertEqual(try XCTUnwrap(r.value), 38, accuracy: 1e-9)
        XCTAssertEqual(r.status, "estimated")
        XCTAssertEqual(r.anchorTime, time(60))
        XCTAssertEqual(r.validationStatus, "experimental_unvalidated")
    }

    func testLateNativeArrivalIsSeparateFromHistoricalPrediction() throws {
        let m = try model(.fullResidual)
        let s = samples + [sample(60, 2), sample(660, 3)]
        let a = anchors + [anchor(60, 30), anchor(660, 90, delay: 60)]
        let initial = try m.estimate(samples: s, anchors: a, at: time(660), asOf: time(660))
        let revision = try m.estimate(samples: s, anchors: a, at: time(660), asOf: time(720))
        XCTAssertEqual(initial.status, "estimated")
        XCTAssertEqual(revision.status, "native_observed")
        XCTAssertEqual(revision.value, 90)
        XCTAssertEqual(revision.anchorAvailableAt, time(720))
        XCTAssertEqual(initial.value, 38)
    }

    func testMissingConflictingStaleAndExtrapolatedInputsDoNotBecomeValues() throws {
        let m = try model(.fullResidual), a = anchors + [anchor(60, 30)]
        XCTAssertEqual(try m.estimate(samples: samples, anchors: a, at: time(660), asOf: time(660)).reason,
                       "missing_stale_or_conflicting_input")
        let s = samples + [sample(60, 2), sample(660, 3), sample(660, 4)]
        XCTAssertNil(try m.estimate(samples: s, anchors: a, at: time(660), asOf: time(660)).value)
        XCTAssertEqual(try m.estimate(samples: samples + [sample(660, 9)], anchors: a, at: time(660), asOf: time(660)).reason,
                       "outside_training_range")
        XCTAssertEqual(try m.estimate(samples: s, anchors: a, at: time(8000), asOf: time(8000)).reason, "stale_anchor")
        XCTAssertEqual(try m.estimate(samples: s, anchors: a + [anchor(60, 40)], at: time(660), asOf: time(660)).reason,
                       "conflicting_anchor")
    }

    func testTenMinuteReplayKeepsMissingSlotsAndNativeObservations() throws {
        let m = try model(.fullResidual)
        let r = try m.tenMinuteSeries(samples: samples + [sample(0, 2), sample(600, 3)],
            anchors: anchors + [anchor(0, 30)], start: base, end: time(2400))
        XCTAssertEqual(r.count, 4)
        XCTAssertEqual(r.map(\.at), [time(0), time(600), time(1200), time(1800)])
        XCTAssertEqual(r[0].status, "native_observed")
        XCTAssertEqual(r[1].status, "estimated")
        XCTAssertEqual(r[3].status, "unavailable")
        XCTAssertNil(r[3].value)
        let distant = Date(timeIntervalSinceReferenceDate: 1e20)
        XCTAssertThrowsError(try m.tenMinuteSeries(samples: [], anchors: [], start: distant,
            end: Date(timeIntervalSinceReferenceDate: 1e20 + 1_000_000)))
    }

    func testLearnedDecayUsesPastDayErrorsAndDoesNotTreatInsufficientDataAsZero() throws {
        let s = [0.0, 3600, 7200, 86400, 90000].map { sample($0, 60) }
        let a = [anchor(0, 40), anchor(3600, 40), anchor(7200, 40), anchor(86400, 80), anchor(90000, 60)]
        let cutoff = time(176400)
        let c = RingFatigueConfiguration(correction: .learnedDecay, minimumTrainingSamples: 3)
        let m = try RingFatigueEstimator(samples: s, anchors: a, before: cutoff, asOf: cutoff, configuration: c)
        XCTAssertEqual(m.residualPairs, 1)
        // A frozen prediction of 40 gives residuals 40 then 20 one hour apart.
        XCTAssertEqual(try XCTUnwrap(m.retentionPerHour), 0.5, accuracy: 1e-12)
        let future = try RingFatigueEstimator(samples: s + [sample(180000, 100)], anchors: a + [anchor(180000, 255)],
            before: cutoff, asOf: cutoff, configuration: c)
        XCTAssertEqual(m.retentionPerHour, future.retentionPerHour)
        let empty = try RingFatigueEstimator(samples: [], anchors: [], before: base, asOf: base, configuration: c)
        let r = try empty.estimate(samples: [sample(0, 60)], anchors: [anchor(-60, 50)], at: base, asOf: base)
        XCTAssertEqual(r.reason, "insufficient_training")
        XCTAssertNil(r.value)
    }

    func testDecayCalibrationReconstructsHistoricalConflictsAndDoesNotMixDailyModels() throws {
        let s = [0.0, 3600, 7200, 86400, 90000].map { sample($0, 60) }
        let a = [anchor(0, 40), anchor(3600, 40), anchor(7200, 40), anchor(86400, 80), anchor(90000, 60)]
        let c = RingFatigueConfiguration(correction: .learnedDecay, minimumTrainingSamples: 3)
        let cutoff = time(176400)
        for lateConflicts in [[], [anchor(0, 90, delay: 174600)]] {
            let m = try RingFatigueEstimator(samples: s, anchors: a + lateConflicts,
                before: cutoff, asOf: cutoff, configuration: c)
            XCTAssertEqual(m.trainingSamples, lateConflicts.isEmpty ? 5 : 4)
            XCTAssertEqual(m.residualPairs, 1)
            XCTAssertEqual(try XCTUnwrap(m.retentionPerHour), 0.5, accuracy: 1e-12)
        }
        let midnight = try RingFatigueEstimator(
            samples: [0.0, 3600, 7200, 169200, 172800].map { sample($0, 60) },
            anchors: [anchor(0, 40), anchor(3600, 40), anchor(7200, 40), anchor(169200, 100), anchor(172800, 100)],
            before: cutoff, asOf: cutoff, configuration: c)
        // The daily intercept changes from 40 to 55. That refit is not signal decay.
        XCTAssertEqual(midnight.residualPairs, 0)
        XCTAssertNil(midnight.retentionPerHour)
    }

    func testDecayCalibrationUsesAnchorReceiptAndCurrentForecastKnowledge() throws {
        let seedSamples = [0.0, 3600, 7200].map { sample($0, 60) }
        let seedAnchors = [anchor(0, 40), anchor(3600, 40), anchor(7200, 40)]
        let c = RingFatigueConfiguration(correction: .learnedDecay, minimumTrainingSamples: 3)
        let cutoff = time(172800)
        let unavailableAnchor = try RingFatigueEstimator(
            samples: seedSamples + [sample(86400, 60), sample(90000, 60)],
            anchors: seedAnchors + [anchor(86400, 80, delay: 7200), anchor(90000, 60)],
            before: cutoff, asOf: cutoff, configuration: c)
        XCTAssertEqual(unavailableAnchor.residualPairs, 0)
        XCTAssertNil(unavailableAnchor.retentionPerHour)
        let conflictingPredecessor = try RingFatigueEstimator(
            samples: seedSamples + [sample(86400, 60), sample(90000, 60)],
            anchors: seedAnchors + [anchor(86400, 80), anchor(88200, 70), anchor(88200, 90), anchor(90000, 60)],
            before: cutoff, asOf: cutoff, configuration: c)
        XCTAssertEqual(conflictingPredecessor.residualPairs, 0)
        XCTAssertNil(conflictingPredecessor.retentionPerHour)
        // Delayed labels may evaluate a forecast, but delayed current inputs cannot create one.
        for inputDelay in [0.0, 3600] {
            let m = try RingFatigueEstimator(
                samples: seedSamples + [sample(86400, 60), sample(90000, 60, delay: inputDelay)],
                anchors: seedAnchors + [anchor(86400, 80), anchor(90000, 60, delay: 3600)],
                before: cutoff, asOf: cutoff, configuration: c)
            XCTAssertEqual(m.residualPairs, inputDelay == 0 ? 1 : 0)
            XCTAssertEqual(m.retentionPerHour, inputDelay == 0 ? 0.5 : nil)
        }
        let receivedAnchor = try RingFatigueEstimator(
            samples: [sample(0, 60), sample(3600, 70), sample(7200, 80), sample(86100, 60),
                      sample(86400, 70, delay: 1800), sample(90000, 70)],
            anchors: [anchor(0, 10), anchor(3600, 20), anchor(7200, 30),
                      anchor(86400, 50, delay: 1800), anchor(90000, 35)],
            before: cutoff, asOf: cutoff, configuration: c)
        // Anchor inputs are frozen at receipt (HR70), not measurement (then only HR60 was known).
        XCTAssertEqual(receivedAnchor.residualPairs, 1)
        XCTAssertEqual(try XCTUnwrap(receivedAnchor.retentionPerHour), 0.5, accuracy: 1e-12)
    }

    func testFeatureAdapterKeepsEmptyAndUnobservedSleepInputsMissing() throws {
        let empty = RingStressFeatureSet(at: base, timeZone: "GMT", maximumAgeSeconds: 600,
            contexts: [RingStressInputContext(command: 0x55, recordedAt: base, ageSeconds: 0,
                withinAgeLimit: true, records: [])], missingCommands: [], sleep: nil,
            heartRateReference: nil, decodingIssues: [], transferCompletenessKnown: false)
        // Public Codable inputs need not have been produced by assemble().
        let decoded = try JSONDecoder().decode(RingStressFeatureSet.self, from: JSONEncoder().encode(empty))
        XCTAssertTrue(RingFatigueSample(inputs: decoded, availableAt: base).values.isEmpty)

        let zone = TimeZone(secondsFromGMT: 0)!
        let stamp = RingTimestamp(year: 2024, month: 1, day: 1, hour: 0, minute: 0, second: 0)
        var h = RingDecodedHistory(command: 0x53)
        h.sleep = [RingSleepRecord(timestamp: stamp, sampleIntervalMinutes: 1, categoryValues: [10, 10], rawBytes: [])]
        let window = DateInterval(start: base, end: time(120))
        let unknown = try RingStressInputs.assemble([h], at: time(120), timeZone: zone, maximumAge: 600,
            sleepWindow: window, sleepMapping: .issinFirmware0750)
        XCTAssertTrue(RingFatigueSample(inputs: unknown, availableAt: time(120)).values.isEmpty)

        h.sleep = [RingSleepRecord(timestamp: stamp, sampleIntervalMinutes: 1, categoryValues: [1], rawBytes: []),
            RingSleepRecord(timestamp: RingTimestamp(year: 2024, month: 1, day: 1, hour: 4, minute: 0, second: 0),
                sampleIntervalMinutes: 1, categoryValues: [1], rawBytes: [])]
        let missing = try RingStressInputs.assemble([h], at: time(15000), timeZone: zone, maximumAge: 600,
            sleepWindow: DateInterval(start: time(7200), end: time(10800)), sleepMapping: .issinFirmware0750)
        XCTAssertEqual(missing.sleep?.intervals.map(\.stage), [.missing])
        XCTAssertTrue(RingFatigueSample(inputs: missing, availableAt: time(15000)).values.isEmpty)

        h.sleep = [RingSleepRecord(timestamp: stamp, sampleIntervalMinutes: 1, categoryValues: [1, 10], rawBytes: [])]
        let partial = try RingStressInputs.assemble([h], at: time(120), timeZone: zone, maximumAge: 600,
            sleepWindow: window, sleepMapping: .issinFirmware0750)
        let observed = RingFatigueSample(inputs: partial, availableAt: time(120)).values
        XCTAssertEqual(observed["sleepDeepObservedSeconds"], 60)
        XCTAssertEqual(observed["sleepAwakeObservedSeconds"], 0)
    }

    func testInvalidPoliciesValuesAndKnowledgeTimeFailAtBoundary() throws {
        XCTAssertThrowsError(try RingFatigueEstimator(samples: samples, anchors: anchors, before: base, asOf: base,
            configuration: RingFatigueConfiguration(correction: .fullResidual, featureNames: ["nativeFatigueRaw"])))
        XCTAssertThrowsError(try RingFatigueEstimator(samples: [sample(-60, .nan)], anchors: anchors,
            before: base, asOf: base, configuration: RingFatigueConfiguration(correction: .fullResidual)))
        XCTAssertThrowsError(try model(.fullResidual).estimate(samples: samples, anchors: anchors, at: time(-60), asOf: base))
        let extreme = try RingFatigueEstimator(
            samples: [sample(-10800, 1e200), sample(-7200, 2e200), sample(-3600, 3e200)],
            anchors: [anchor(-10800, 10), anchor(-7200, 20), anchor(-3600, 30)], before: base, asOf: base,
            configuration: RingFatigueConfiguration(correction: .unanchored, minimumTrainingSamples: 3))
        let rejected = try extreme.estimate(samples: [sample(0, 2e200)], anchors: [anchor(-3600, 30)], at: base, asOf: base)
        XCTAssertEqual(rejected.reason, "invalid_training_fit")
        XCTAssertNil(rejected.value)
        let zone = TimeZone(secondsFromGMT: 0)!
        let at = RingTimestamp(year: 2024, month: 1, day: 1, hour: 0, minute: 0, second: 0)
        var h = RingDecodedHistory(command: 0x56)
        h.hrv = [RingHRVRecord(timestamp: at, hrvRaw: 40, heartRateBPM: 60, stressRaw: 30, rawBytes: [])]
        let inputs = try RingStressInputs.assemble([h], at: at.date(in: zone)!, timeZone: zone, maximumAge: 600)
        XCTAssertTrue(RingFatigueSample(inputs: inputs, availableAt: base).values.isEmpty)
    }
}
