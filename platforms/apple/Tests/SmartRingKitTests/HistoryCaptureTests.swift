import Foundation
import XCTest
@testable import SmartRingKit

final class HistoryCaptureTests: XCTestCase {
    func testPartialCaptureRetainsPacketBoundariesWithoutExceedingBudget() {
        var capture = RingHistoryCaptureBuffer(command: .hrvHistory, maxBytes: 5)
        // Even a truncated packet must remain available for diagnosis.
        XCTAssertTrue(capture.append(Data([0x56, 0x00, 0x00])))
        XCTAssertTrue(capture.append(Data([0x56, 0xff])))
        XCTAssertFalse(capture.append(Data([0x56, 0x00])))
        XCTAssertEqual(capture.notifications, [[0x56, 0x00, 0x00], [0x56, 0xff]])
        XCTAssertNotNil(capture.limitFailure)
    }

    func testConflictingHistoryStillStopsCaptureWhenUnexpectedBudgetIsFull() {
        var capture = RingHistoryCaptureBuffer(command: .hrvHistory, maxBytes: 2)
        XCTAssertTrue(capture.append(Data([0x13, 85])))
        let otherCommand = RingReadCommand.historyCommands.first { $0 != .hrvHistory }!
        XCTAssertFalse(capture.append(Data([otherCommand.rawValue, 0xff])))
        XCTAssertEqual(capture.conflictingCommand, otherCommand.rawValue)
        XCTAssertEqual(capture.unexpectedNotifications, [[0x13, 85]])
        XCTAssertNotNil(capture.limitFailure)
        XCTAssertTrue(capture.notifications.isEmpty)
    }

    #if canImport(CoreBluetooth)
    @MainActor func testInvalidSnapshotLimitsFailBeforeBluetoothDiscovery() async {
        for timeout in [0.0, -1.0, Double.infinity, Double.nan] {
            do {
                _ = try await RingHistoryReader.readAll(from: UUID(), timeoutPerHistory: timeout)
                XCTFail("expected invalid timeout to fail before discovery")
            } catch { XCTAssertEqual(error as? RingError, .timedOut) }
        }
        do {
            _ = try await RingHistoryReader.readAll(from: UUID(), maxBytesPerHistory: 0)
            XCTFail("expected invalid byte limit to fail before discovery")
        } catch {
            guard let ringError = error as? RingError, case .invalidPacket = ringError else {
                XCTFail("expected invalid packet error, got \(error)")
                return
            }
        }
    }
    #endif
}
