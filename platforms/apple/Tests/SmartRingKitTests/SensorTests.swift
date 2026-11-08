import Foundation
import XCTest
@testable import SmartRingKit

final class SensorTests: XCTestCase {
    private func row(_ command: RingReadCommand, width: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: width)
        b[0] = command.rawValue
        b.replaceSubrange(3...8, with: [0x24, 2, 0x29, 0x12, 0, 0])
        return b
    }

    func testScalarOxygenSpotHeartRateAndTemperaturePreserveRawData() throws {
        for (cmd, width, expected, unit) in [(RingReadCommand.oxygenHistory, 10, "oxygenSaturation", "%"),
                                           (.spotHeartRateHistory, 10, "heartRate", "bpm"),
                                           (.temperatureHistory, 15, "temperatureSDKValue", "")] {
            var b = row(cmd, width: width); b[9] = 97
            let decoded = RingHistoryCodec.decode(RingRawHistory(command: cmd.rawValue, notifications: [b, [cmd.rawValue, 255]]))
            XCTAssertTrue(decoded.issues.isEmpty)
            let r = try XCTUnwrap(decoded.sensors.first)
            XCTAssertEqual(r.rawBytes, b)
            XCTAssertEqual(r.measurements[0].name, expected)
            XCTAssertEqual(r.measurements[0].unit ?? "", unit)
        }
    }

    func testDynamicHeartRateKeepsSamplesWithoutInventingSampleTimes() throws {
        var b = row(.heartRateHistory, width: 24)
        b.replaceSubrange(9...23, with: Array(60...74).map(UInt8.init))
        let decoded = RingHistoryCodec.decode(RingRawHistory(command: 0x54, notifications: [b + [0x54, 255]]))
        XCTAssertTrue(decoded.issues.isEmpty)
        let series = try XCTUnwrap(decoded.sensors.first?.series.first)
        XCTAssertEqual(series.values, Array(60...74).map(UInt8.init))
        XCTAssertNil(series.intervalSeconds)
    }

    func testDailyUnsignedCountsAndUnknownPacketAreNotLost() throws {
        var b = [UInt8](repeating: 0, count: 27)
        b[0] = 0x51; b[2] = 0x24; b[3] = 2; b[4] = 0x29
        b.replaceSubrange(5...8, with: [255, 255, 255, 255])
        let bad: [UInt8] = [0x51, 0, 0]
        let decoded = RingHistoryCodec.decode(RingRawHistory(command: 0x51, notifications: [b, bad, [0x51, 255]]))
        XCTAssertEqual(decoded.sensors.count, 1)
        XCTAssertTrue(decoded.sensors[0].dateOnly)
        XCTAssertEqual(decoded.sensors[0].measurements[0].value, 4_294_967_295)
        XCTAssertEqual(decoded.unparsedNotifications, [bad])
        XCTAssertEqual(decoded.issues.count, 1)
    }

    func testExtendedManualOxygenRecordsStayStructuredButUninterpreted() {
        var a = [UInt8](repeating: 0, count: 31)
        a[0] = 0x67
        a[3] = 0xff
        let decoded = RingHistoryCodec.decode(RingRawHistory(command: 0x67, notifications: [a + a + [0x67, 255]]))
        XCTAssertEqual(decoded.opaqueRecords.count, 2)
        XCTAssertEqual(decoded.opaqueRecords[0].rawBytes, a)
        XCTAssertTrue(decoded.sensors.isEmpty)
        XCTAssertTrue(decoded.issues.isEmpty)
    }

    func testObservedSequenceDiagnosticsExposeGapsDuplicatesAndWrap() throws {
        func r(_ id: UInt16) -> [UInt8] { [0x54, UInt8(id & 255), UInt8(id >> 8)] }
        let gaps = try XCTUnwrap(RingHistoryIntegrity.analyze([r(0), r(2), r(2), r(1)], daily: false))
        XCTAssertEqual(gaps.missingSequenceValues, 1)
        XCTAssertEqual(gaps.duplicateTransitions, 1)
        XCTAssertEqual(gaps.outOfOrderTransitions, 1)
        XCTAssertFalse(gaps.isContiguous)
        XCTAssertTrue(try XCTUnwrap(RingHistoryIntegrity.analyze([r(65535), r(0), r(1)], daily: false)).isContiguous)
    }

    private func sleep(_ values: [UInt8], minute: UInt8 = 0, second: UInt8 = 0) throws -> RingSleepRecord {
        var b = row(.sleepHistory, width: 130)
        b[7] = minute; b[8] = second; b[9] = UInt8(values.count)
        b.replaceSubrange(10..<(10 + values.count), with: values)
        var parser = RingSleepHistoryDecoder(); try parser.append(Data(b))
        return try XCTUnwrap(parser.records.first)
    }

    func testSleepStagesPreserveUnknownCodesAndMergeMinuteJitter() throws {
        let result = try RingSleepAnalyzer.analyze([sleep([1, 2, 3, 5, 10, 11], second: 1)],
                                                  timeZone: TimeZone(secondsFromGMT: 0)!, mapping: .issinFirmware0750)
        XCTAssertEqual(result.intervals.map(\.stage), [.deep, .light, .rem, .awake, .unknown, .unknown])
        XCTAssertEqual(result.durations.first { $0.stage == .unknown }?.seconds, 120)
        XCTAssertEqual(result.intervals[0].start.timeIntervalSince1970.truncatingRemainder(dividingBy: 60), 0)
    }

    func testOverlappingSleepDoesNotDoubleCountOrHideConflictsAndMissingCoverage() throws {
        let result = try RingSleepAnalyzer.analyze([sleep([1, 2]), sleep([1, 3]), sleep([5], minute: 4)],
                                                  timeZone: TimeZone(secondsFromGMT: 0)!, mapping: .issinFirmware0750)
        XCTAssertEqual(result.duplicateSamples, 1)
        XCTAssertEqual(result.conflictingMinutes, 1)
        XCTAssertEqual(result.intervals.map(\.stage), [.deep, .unknown, .missing, .awake])
        XCTAssertEqual(result.durations.reduce(0) { $0 + $1.seconds }, 300)
        XCTAssertEqual(result.intervals[1].rawValues, [2, 3])
    }

    func testNightWindowDoesNotCountDuplicatesFromOtherTimes() throws {
        let zone = TimeZone(secondsFromGMT: 0)!
        let row = try sleep([2], minute: 3)
        let start = try XCTUnwrap(row.timestamp.date(in: zone))
        let result = try RingSleepAnalyzer.analyze([sleep([1]), sleep([1]), row], timeZone: zone,
            mapping: .issinFirmware0750, window: DateInterval(start: start, duration: 60))
        XCTAssertEqual(result.duplicateSamples, 0)
        XCTAssertEqual(result.intervals.count, 1)
        XCTAssertEqual(result.intervals[0].stage, .light)
    }
}
