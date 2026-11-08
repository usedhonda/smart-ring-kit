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
    }

    func testLearnedDecayUsesPastDayErrorsAndDoesNotTreatInsufficientDataAsZero() throws {
        let s = (1...100).map { sample(Double($0 - 101) * 3600, Double(60 + $0 % 8)) }
        let a = (1...100).map { i -> RingNativeFatigueAnchor in
            let seconds = Double(i - 101) * 3600
            let value = 20 + i % 8 + (i / 8) % 5
            return anchor(seconds, UInt8(value))
        }
        let c = RingFatigueConfiguration(correction: .learnedDecay, minimumTrainingSamples: 4)
        let m = try RingFatigueEstimator(samples: s, anchors: a, before: base, asOf: base, configuration: c)
        XCTAssertGreaterThan(m.residualPairs, 0)
        XCTAssertTrue((0...1).contains(try XCTUnwrap(m.retentionPerHour)))
        let future = try RingFatigueEstimator(samples: s + [sample(3600, 100)], anchors: a + [anchor(3600, 255)],
            before: base, asOf: base, configuration: c)
        XCTAssertEqual(m.retentionPerHour, future.retentionPerHour)
        let empty = try RingFatigueEstimator(samples: [], anchors: [], before: base, asOf: base, configuration: c)
        let r = try empty.estimate(samples: [sample(0, 60)], anchors: [anchor(-60, 50)], at: base, asOf: base)
        XCTAssertEqual(r.reason, "insufficient_training")
        XCTAssertNil(r.value)
    }

    func testInvalidPoliciesValuesAndKnowledgeTimeFailAtBoundary() throws {
        XCTAssertThrowsError(try RingFatigueEstimator(samples: samples, anchors: anchors, before: base, asOf: base,
            configuration: RingFatigueConfiguration(correction: .fullResidual, featureNames: ["nativeFatigueRaw"])))
        XCTAssertThrowsError(try RingFatigueEstimator(samples: [sample(-60, .nan)], anchors: anchors,
            before: base, asOf: base, configuration: RingFatigueConfiguration(correction: .fullResidual)))
        XCTAssertThrowsError(try model(.fullResidual).estimate(samples: samples, anchors: anchors, at: time(-60), asOf: base))
        let zone = TimeZone(secondsFromGMT: 0)!
        let at = RingTimestamp(year: 2024, month: 1, day: 1, hour: 0, minute: 0, second: 0)
        var h = RingDecodedHistory(command: 0x56)
        h.hrv = [RingHRVRecord(timestamp: at, hrvRaw: 40, heartRateBPM: 60, stressRaw: 30, rawBytes: [])]
        let inputs = try RingStressInputs.assemble([h], at: at.date(in: zone)!, timeZone: zone, maximumAge: 600)
        XCTAssertTrue(RingFatigueSample(inputs: inputs, availableAt: base).values.isEmpty)
    }
}
