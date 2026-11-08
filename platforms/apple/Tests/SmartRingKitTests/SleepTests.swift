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

    func testAdditionalRequestsKeepInitialReadModeAndChecksum() {
        for command in [RingReadCommand.sleepHistory, .heartRateHistory, .temperatureHistory,
                        .oxygenHistory, .activityHistory, .dailyActivityHistory] {
            let b = [UInt8](command.packet)
            XCTAssertEqual(b[1], 0)
            XCTAssertEqual(b[15], b.prefix(15).reduce(0, &+))
        }
    }
}
