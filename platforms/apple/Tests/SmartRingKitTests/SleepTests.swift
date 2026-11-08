import Foundation
import XCTest
@testable import SmartRingKit

final class SleepTests: XCTestCase {
    private func record(width: Int, values: [UInt8] = [0, 1, 2, 3]) -> [UInt8] {
        var row = [UInt8](repeating: 0, count: width)
        row.replaceSubrange(0..<10, with: [0x53, 0, 0, 0x24, 0x02, 0x29, 0x23, 0, 0, UInt8(values.count)])
        row.replaceSubrange(10..<(10 + values.count), with: values)
        return row
    }

    func testOneMinuteLayoutWithCombinedTerminatorKeepsUnlabelledCategories() throws {
        var decoder = RingSleepHistoryDecoder()
        let row = record(width: 130)
        try decoder.append(Data(row + [0x53, 0xff]))
        XCTAssertTrue(decoder.isComplete)
        XCTAssertEqual(decoder.records.count, 1)
        XCTAssertEqual(decoder.records[0].sampleIntervalMinutes, 1)
        XCTAssertEqual(decoder.records[0].categoryValues, [0, 1, 2, 3])
        XCTAssertEqual(decoder.records[0].timestamp.day, 29)
        XCTAssertEqual(decoder.records[0].rawBytes, row)
    }

    func testFiveMinuteBatchesAndSeparateTerminator() throws {
        var decoder = RingSleepHistoryDecoder()
        var row = record(width: 34)
        row[32] = 0x53; row[33] = 0xff
        try decoder.append(Data(row + row))
        XCTAssertFalse(decoder.isComplete)
        try decoder.append(Data([0x53, 0xff]))
        XCTAssertTrue(decoder.isComplete)
        XCTAssertEqual(decoder.records.map(\.sampleIntervalMinutes), [5, 5])
        XCTAssertThrowsError(try decoder.append(Data([0x53, 0xff])))
    }

    func testMalformedLengthsDatesAndOversizedCategoryCountsFailAtomically() throws {
        var decoder = RingSleepHistoryDecoder()
        XCTAssertThrowsError(try decoder.append(Data(record(width: 34).dropLast())))
        var invalidCount = record(width: 34); invalidCount[9] = 25
        XCTAssertThrowsError(try decoder.append(Data(record(width: 34) + invalidCount)))
        var invalidDate = record(width: 130); invalidDate[4] = 0x13
        XCTAssertThrowsError(try decoder.append(Data(invalidDate)))
        XCTAssertTrue(decoder.records.isEmpty)
    }

    func testSleepLimitAndEmptyHistory() throws {
        var decoder = RingSleepHistoryDecoder(maxRecords: 1)
        XCTAssertThrowsError(try decoder.append(Data(record(width: 34) + record(width: 34))))
        XCTAssertTrue(decoder.records.isEmpty)
        try decoder.append(Data([0x53, 0xff]))
        XCTAssertTrue(decoder.isComplete)
    }

    func testRawHistoryPreservesNotificationsAndEnforcesLimitsAndCommand() throws {
        var decoder = try RingRawHistoryDecoder(command: .temperatureHistory, maxBytes: 8)
        try decoder.append(Data([0x62, 0, 0]))
        XCTAssertFalse(decoder.isComplete)
        XCTAssertThrowsError(try decoder.append(Data([0x66, 0xff])))
        XCTAssertThrowsError(try decoder.append(Data([0x62, 0, 0, 0, 0, 0])))
        XCTAssertEqual(decoder.byteCount, 3)
        try decoder.append(Data([0x62, 0xff]))
        XCTAssertTrue(decoder.isComplete)
        XCTAssertEqual(decoder.result.notifications, [[0x62, 0, 0], [0x62, 0xff]])
        XCTAssertThrowsError(try RingRawHistoryDecoder(command: .firmware))
    }

    func testRawCompletionRequiresRecordBoundary() throws {
        let layouts: [(RingReadCommand, Int)] = [
            (.hrvHistory, 15), (.sleepHistory, 34), (.sleepHistory, 130), (.heartRateHistory, 24),
            (.spotHeartRateHistory, 10), (.oxygenHistory, 10), (.manualOxygenHistory, 10),
            (.manualOxygenHistory, 31), (.temperatureHistory, 11), (.temperatureHistory, 15),
            (.activityHistory, 25), (.exerciseHistory, 25), (.dailyActivityHistory, 26), (.dailyActivityHistory, 27)
        ]
        for (command, width) in layouts {
            var row = [UInt8](repeating: 0, count: width)
            row[0] = command.rawValue
            row[width - 2] = command.rawValue
            row[width - 1] = 0xff
            var decoder = try RingRawHistoryDecoder(command: command)
            try decoder.append(Data(row))
            XCTAssertFalse(decoder.isComplete, "\(command) width \(width)")
            try decoder.append(Data(row + [command.rawValue, 0xff]))
            XCTAssertTrue(decoder.isComplete, "\(command) width \(width)")
            XCTAssertEqual(decoder.notifications, [row, row + [command.rawValue, 0xff]])
        }

        var decoder = try RingRawHistoryDecoder(command: .temperatureHistory)
        let unknown: [UInt8] = [0x62, 0, 0x62, 0xff]
        try decoder.append(Data(unknown))
        XCTAssertFalse(decoder.isComplete)
        // This is both seven complete 11-byte records and five 15-byte records
        // followed by marker-shaped payload bytes: do not end an ambiguous frame.
        var ambiguous = [UInt8](repeating: 0x62, count: 77)
        ambiguous[76] = 0xff
        try decoder.append(Data(ambiguous))
        XCTAssertFalse(decoder.isComplete)
        try decoder.append(Data([0x62, 0xff]))
        XCTAssertTrue(decoder.isComplete)
        XCTAssertEqual(decoder.notifications, [unknown, ambiguous, [0x62, 0xff]])
    }
}
