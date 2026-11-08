import Foundation
import XCTest
@testable import SmartRingKit

final class StressInputTests: XCTestCase {
    private let zone = TimeZone(secondsFromGMT: 0)!
    private func stamp(_ minute: Int) -> RingTimestamp {
        RingTimestamp(year: 2024, month: 2, day: 29, hour: 12, minute: minute, second: 0)
    }
    private func heart(_ minute: Int, _ bpm: UInt8, counter: UInt8 = 0) -> RingSensorRecord {
        RingSensorRecord(timestamp: stamp(minute), dateOnly: false, format: "fff0-55-10",
            measurements: [RingMeasurement(name: "heartRate", value: Double(bpm), unit: "bpm")],
            series: [], rawBytes: [0x55, counter, 0, 0x24, 2, 0x29, 0x12, UInt8(minute), 0, bpm])
    }
    private func history(_ rows: [RingSensorRecord]) -> RingDecodedHistory {
        var h = RingDecodedHistory(command: 0x55); h.sensors = rows; return h
    }

    func testFutureRecordsNeverReplaceCurrentAndReferenceExcludesCurrent() throws {
        let h = history([heart(0, 60), heart(10, 70), heart(20, 80), heart(30, 90), heart(40, 200)])
        for minute in [30, 31] {
            let at = stamp(minute).date(in: zone)!
            let result = try RingStressInputs.assemble([h], at: at, timeZone: zone, maximumAge: 60,
                referenceWindow: DateInterval(start: stamp(0).date(in: zone)!, end: at))
            let current = try XCTUnwrap(result.contexts.first)
            XCTAssertEqual(current.records.first?.measurements.first?.value, 90)
            XCTAssertEqual(result.heartRateReference?.sampleCount, 3)
            XCTAssertEqual(result.heartRateReference?.medianBPM, 70)
            XCTAssertEqual(result.heartRateReference?.medianAbsoluteDeviationBPM, 10)
            XCTAssertEqual(result.heartRateReference?.currentDifferenceBPM, 20)
            XCTAssertEqual(result.heartRateReference?.normalizedDifference, 2)
            XCTAssertFalse(result.transferCompletenessKnown)
        }
    }

    func testChangedCountersDeduplicateButLatestConflictCannotBecomeScoreInput() throws {
        let at = stamp(30).date(in: zone)!
        let result = try RingStressInputs.assemble([history([heart(0, 60), heart(0, 60, counter: 9),
            heart(10, 70), heart(30, 90), heart(30, 100)])], at: at, timeZone: zone, maximumAge: 60,
            referenceWindow: DateInterval(start: stamp(0).date(in: zone)!, end: at))
        XCTAssertTrue(try XCTUnwrap(result.contexts.first).isConflicting)
        XCTAssertEqual(result.heartRateReference?.sampleCount, 2)
        XCTAssertNil(result.heartRateReference?.currentDifferenceBPM)
    }

    func testStaleAndMissingRemainDistinctAndZeroDispersionIsNotZeroStress() throws {
        let at = stamp(30).date(in: zone)!
        let result = try RingStressInputs.assemble([history([heart(0, 60), heart(10, 60)])],
            at: at, timeZone: zone, maximumAge: 60,
            referenceWindow: DateInterval(start: stamp(0).date(in: zone)!, end: at))
        XCTAssertEqual(result.contexts.first?.ageSeconds, 1200)
        XCTAssertEqual(result.contexts.first?.withinAgeLimit, false)
        XCTAssertFalse(result.missingCommands.contains(0x55))
        XCTAssertTrue(result.missingCommands.contains(0x56))
        XCTAssertEqual(result.heartRateReference?.sampleCount, 2)
        XCTAssertNil(result.heartRateReference?.currentDifferenceBPM)
        XCTAssertNil(result.heartRateReference?.normalizedDifference)
    }

    func testExplicitSleepWindowClipsCompletedStagesAndKeepsUnknowns() throws {
        let at = stamp(2).date(in: zone)!
        var h = RingDecodedHistory(command: 0x53)
        h.sleep = [RingSleepRecord(timestamp: stamp(0), sampleIntervalMinutes: 1,
                                  categoryValues: [1, 99, 3, 5], rawBytes: [])]
        let result = try RingStressInputs.assemble([h], at: at, timeZone: zone, maximumAge: 60,
            sleepWindow: DateInterval(start: stamp(0).date(in: zone)!, end: at), sleepMapping: .issinFirmware0750)
        XCTAssertEqual(result.sleep?.durations.first { $0.stage == .deep }?.seconds, 60)
        XCTAssertEqual(result.sleep?.durations.first { $0.stage == .unknown }?.seconds, 60)
        XCTAssertEqual(result.sleep?.durations.first { $0.stage == .rem }?.seconds, 0)
        XCTAssertTrue(try XCTUnwrap(result.sleep).intervals.allSatisfy { $0.end <= at })
        XCTAssertThrowsError(try RingStressInputs.assemble([h], at: at, timeZone: zone, maximumAge: 60,
            sleepWindow: DateInterval(start: stamp(0).date(in: zone)!, end: at)))
        XCTAssertThrowsError(try RingStressInputs.assemble([h], at: at, timeZone: zone, maximumAge: 60,
            referenceWindow: DateInterval(start: at, end: at.addingTimeInterval(60))))

        let pastWindow = DateInterval(start: stamp(0).date(in: zone)!.addingTimeInterval(30),
                                      end: stamp(1).date(in: zone)!.addingTimeInterval(30))
        let past = try RingStressInputs.assemble([h], at: at, timeZone: zone, maximumAge: 60,
            sleepWindow: pastWindow, sleepMapping: .issinFirmware0750)
        XCTAssertEqual(past.sleep?.durations.first { $0.stage == .deep }?.seconds, 30)
        XCTAssertEqual(past.sleep?.durations.first { $0.stage == .unknown }?.seconds, 30)

        h.sleep = [RingSleepRecord(timestamp: stamp(0), sampleIntervalMinutes: 5,
                                  categoryValues: [1, 3], rawBytes: [])]
        let window = DateInterval(start: stamp(2).date(in: zone)!, end: stamp(7).date(in: zone)!)
        for (minute, remSeconds) in [(7, 0.0), (10, 120.0)] {
            let clipped = try RingStressInputs.assemble([h], at: stamp(minute).date(in: zone)!,
                timeZone: zone, maximumAge: 60, sleepWindow: window, sleepMapping: .issinFirmware0750)
            XCTAssertEqual(clipped.sleep?.durations.first { $0.stage == .deep }?.seconds, 180)
            XCTAssertEqual(clipped.sleep?.durations.first { $0.stage == .rem }?.seconds, remSeconds)
            XCTAssertTrue(try XCTUnwrap(clipped.sleep).intervals.allSatisfy { $0.start >= window.start && $0.end <= window.end })
        }
    }

    func testUnknownUnitsAndSamplingIntervalsSurviveAssembly() throws {
        var hrv = RingDecodedHistory(command: 0x56)
        hrv.hrv = [RingHRVRecord(timestamp: stamp(0), hrvRaw: 42, heartRateBPM: 70, stressRaw: 51, rawBytes: [])]
        var activity = RingDecodedHistory(command: 0x52)
        activity.sensors = [RingSensorRecord(timestamp: stamp(0), dateOnly: false, format: "fff0-52-25",
            measurements: [RingMeasurement(name: "steps", value: 0, unit: "count")],
            series: [RingSampleSeries(name: "steps", values: [0, 0], unit: "count", intervalSeconds: nil)], rawBytes: [])]
        let result = try RingStressInputs.assemble([hrv, activity], at: stamp(1).date(in: zone)!,
                                                  timeZone: zone, maximumAge: 120)
        let h = try XCTUnwrap(result.contexts.first { $0.command == 0x56 })
        XCTAssertNil(h.records[0].measurements.first { $0.name == "hrvRaw" }?.unit)
        XCTAssertEqual(h.records[0].measurements.first { $0.name == "nativeFatigueRaw" }?.value, 51)
        XCTAssertNil(result.contexts.first { $0.command == 0x52 }?.records[0].series[0].intervalSeconds)
    }

    func testDistantEvaluationWindowDoesNotOverflowSleepSampleCount() throws {
        let at = Date(timeIntervalSince1970: 1e20)
        var h = RingDecodedHistory(command: 0x53)
        h.sleep = [RingSleepRecord(timestamp: stamp(0), sampleIntervalMinutes: 1, categoryValues: [1], rawBytes: [])]
        let result = try RingStressInputs.assemble([h], at: at, timeZone: zone, maximumAge: 60,
            sleepWindow: DateInterval(start: stamp(0).date(in: zone)!, end: at), sleepMapping: .issinFirmware0750)
        XCTAssertEqual(result.sleep?.durations.first { $0.stage == .deep }?.seconds, 60)
    }
}
