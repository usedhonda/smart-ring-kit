import Foundation
import XCTest
@testable import SmartRingKit

final class HistoryIdleTests: XCTestCase {
    func testPausedHistoryCannotLookIdleBeforeItsTerminator() throws {
        let start = Date(timeIntervalSince1970: 0)
        var gate = RingHistoryIdleGate(quietPeriod: 5, maxBytes: 1000, startedAt: start)
        XCTAssertTrue(gate.isQuiet(at: start.addingTimeInterval(5)))
        var row = [UInt8](repeating: 0, count: 15)
        row[0] = 0x56; row[13] = 0x56; row[14] = 0xff
        try gate.observe(Data(row), at: start.addingTimeInterval(6))
        XCTAssertFalse(gate.isQuiet(at: start.addingTimeInterval(60)))
        try gate.observe(Data([0x56, 0xff]), at: start.addingTimeInterval(61))
        XCTAssertFalse(gate.isQuiet(at: start.addingTimeInterval(65)))
        XCTAssertTrue(gate.isQuiet(at: start.addingTimeInterval(66)))
    }

    func testObservationBudgetIncludesUnexpectedTraffic() throws {
        var gate = RingHistoryIdleGate(quietPeriod: 5, maxBytes: 2, startedAt: .distantPast)
        try gate.observe(Data([0x27, 0]), at: Date())
        XCTAssertThrowsError(try gate.observe(Data([0x13]), at: Date()))
    }
}
