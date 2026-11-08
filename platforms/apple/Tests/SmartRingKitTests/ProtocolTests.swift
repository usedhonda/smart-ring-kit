import Foundation
import XCTest
@testable import SmartRingKit

final class ProtocolTests: XCTestCase {
    // Entirely synthetic, including the date and device-labelled values.
    private let record: [UInt8] = [0x56, 0, 0, 0x24, 0x02, 0x29, 0x12, 0x34, 0x56, 42, 0, 65, 30, 0, 0]

    func testReadRequestsCannotSelectDeleteMode() {
        for command in RingReadCommand.allCases {
            let bytes = [UInt8](command.packet)
            XCTAssertEqual(bytes.count, 16)
            XCTAssertEqual(bytes[1], 0)
            XCTAssertEqual(bytes[15], bytes.prefix(15).reduce(0, &+))
            let continuation = [UInt8](command.readPacket(continuing: true))
            XCTAssertEqual(continuation.count, 16)
            XCTAssertEqual(continuation[1], command.isHistory ? 2 : 0)
            XCTAssertEqual(continuation[15], continuation.prefix(15).reduce(0, &+))
        }
        XCTAssertFalse(RingReadCommand.historyCommands.contains(.deviceClock))
        XCTAssertEqual(RingReadCommand.historyCommands.count, 10)
    }

    func testBoundedHistoryPacketsKeepBCDDateAcrossContinuation() throws {
        let start = RingTimestamp(year: 2024, month: 2, day: 29, hour: 13, minute: 45, second: 6)
        for command in [RingReadCommand.spotHeartRateHistory, .hrvHistory, .temperatureHistory] {
            let initial = [UInt8](try command.historyRequest(resumingFrom: start))
            let next = [UInt8](try command.readPacket(continuing: true, resumingFrom: start))
            XCTAssertEqual(Array(initial[4...9]), [0x24, 0x02, 0x29, 0x13, 0x45, 0x06])
            XCTAssertEqual(initial[1], 0)
            XCTAssertEqual(next[1], 2)
            XCTAssertEqual(Array(initial[2...14]), Array(next[2...14]))
            for packet in [initial, next] {
                XCTAssertEqual(packet[0], command.rawValue)
                XCTAssertEqual(packet[15], packet.prefix(15).reduce(0, &+))
            }
        }
        XCTAssertThrowsError(try RingReadCommand.firmware.historyRequest(resumingFrom: start))
        XCTAssertThrowsError(try RingReadCommand.sleepHistory.historyRequest(resumingFrom: start))
        for invalid in [
            RingTimestamp(year: 2100, month: 1, day: 1, hour: 0, minute: 0, second: 0),
            RingTimestamp(year: 2023, month: 2, day: 29, hour: 0, minute: 0, second: 0),
            RingTimestamp(year: 2024, month: 1, day: 1, hour: -1, minute: 0, second: 0)
        ] {
            XCTAssertThrowsError(try RingReadCommand.hrvHistory.historyRequest(resumingFrom: invalid))
        }
    }

    func testDeviceInfoDecodesAndRejectsCorruption() throws {
        XCTAssertEqual(try RingPacketDecoder.firmware(Data([0x27, 0, 7, 5, 0])), "0.7.5.0")
        XCTAssertEqual(try RingPacketDecoder.battery(Data([0x13, 85])), 85)
        XCTAssertThrowsError(try RingPacketDecoder.firmware(Data([0x27])))
        XCTAssertThrowsError(try RingPacketDecoder.battery(Data([0x13, 101])))
        XCTAssertThrowsError(try RingPacketDecoder.battery(Data([0x27, 85])))
    }

    func testHistoryPreservesValuesAndRequiresRealTerminator() throws {
        var decoder = RingHistoryDecoder()
        var withFF = record
        withFF[14] = 0xff
        try decoder.append(Data(withFF))
        XCTAssertFalse(decoder.isComplete)
        try decoder.append(Data(record + record + [0x56, 0xff]))
        XCTAssertTrue(decoder.isComplete)
        XCTAssertEqual(decoder.records.count, 3)
        let decoded = decoder.records[1]
        XCTAssertEqual(decoded.hrvRaw, 42)
        XCTAssertEqual(decoded.heartRateBPM, 65)
        XCTAssertEqual(decoded.stressRaw, 30)
        XCTAssertEqual(decoded.timestamp.year, 2024)
        XCTAssertEqual(decoded.timestamp.day, 29)
        XCTAssertEqual(decoded.rawBytes, record)
        XCTAssertThrowsError(try decoder.append(Data([0x56, 0xff])))
    }

    func testInvalidDateAndTruncatedNotificationsAreRejected() throws {
        for (index, value) in [(4, UInt8(0x13)), (5, 0x30), (6, 0x24), (7, 0x6a)] {
            var malformed = record
            malformed[index] = value
            XCTAssertThrowsError(try RingPacketDecoder.hrvRecord(Data(malformed)))
        }
        var decoder = RingHistoryDecoder()
        XCTAssertThrowsError(try decoder.append(Data(record.dropLast())))
        XCTAssertThrowsError(try decoder.append(Data(record + [0x56, 0xfe])))
        XCTAssertTrue(decoder.records.isEmpty)

        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let skippedTime = try RingPacketDecoder.timestamp([0x24, 0x03, 0x10, 0x02, 0x30, 0])
        XCTAssertNil(skippedTime.date(in: zone))
        XCTAssertNotNil(skippedTime.date(in: TimeZone(secondsFromGMT: 0)!))
        let validTime = try RingPacketDecoder.timestamp([0x24, 0x03, 0x10, 0x03, 0x30, 0])
        XCTAssertNotNil(validTime.date(in: zone))
    }

    func testHistoryLimitAndAtomicNotification() throws {
        var decoder = RingHistoryDecoder(maxRecords: 1)
        XCTAssertThrowsError(try decoder.append(Data(record + record)))
        XCTAssertTrue(decoder.records.isEmpty)
        try decoder.append(Data(record + [0x56, 0xff]))
        XCTAssertEqual(decoder.records.count, 1)
        XCTAssertTrue(decoder.isComplete)
    }

    func testEmptyHistory() throws {
        var decoder = RingHistoryDecoder()
        try decoder.append(Data([0x56, 0xff]))
        XCTAssertTrue(decoder.isComplete)
        XCTAssertTrue(decoder.records.isEmpty)
    }

    #if canImport(CoreBluetooth)
    @MainActor func testCancelledDiscoveryAndDisconnectedReadFail() async {
        let client = RingClient()
        let task = Task { try await client.discover(duration: 0.1) }
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError || error as? RingError == .cancelled) }
        do { _ = try await client.readInfo(); XCTFail("expected disconnected") }
        catch { XCTAssertEqual(error as? RingError, .disconnected) }
    }
    #endif
}
