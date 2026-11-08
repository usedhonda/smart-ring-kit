import Foundation

/// One history attempt. Partial bytes survive timeouts, unsupported commands and
/// decoding errors. `transferComplete` describes radio framing, not interpretation.
public struct RingHistoryCapture: Codable, Equatable, Sendable {
    public let peripheralID: UUID
    public let command: RingReadCommand
    public let attempted: Bool
    public let startedAt: Date?
    public let transferComplete: Bool
    public let failure: String?
    public let raw: RingRawHistory
    public let unexpectedNotifications: [[UInt8]]
    public let decoded: RingDecodedHistory
}

public struct RingHistorySnapshot: Codable, Sendable {
    public let peripheralID: UUID
    public let capturedAt: Date
    public let info: RingInfo
    public let deviceClock: RingTimestamp?
    public let clockFailure: String?
    public var stopReason: String? = nil
    public var histories: [RingHistoryCapture]
}

#if canImport(CoreBluetooth)
/// Reads all supported stored-history categories through separate connections.
/// No measurements are started and no ring history is erased. Capture callbacks
/// let the host persist progress before a later command fails or is cancelled.
@MainActor
public enum RingHistoryReader {
    public static func readAll(from peripheralID: UUID, timeoutPerHistory: TimeInterval = 120,
                               maxBytesPerHistory: Int = 2_000_000,
                               onCapture: (@MainActor (RingHistoryCapture) throws -> Void)? = nil) async throws -> RingHistorySnapshot {
        let infoClient = RingClient()
        let info: RingInfo
        var clock: RingTimestamp?
        var clockFailure: String?
        do {
            _ = try await infoClient.discover(duration: 1)
            try await infoClient.connect(to: peripheralID)
            info = try await infoClient.readInfo()
            do { clock = try await infoClient.readDeviceClock() }
            catch { clockFailure = error.localizedDescription }
        } catch { infoClient.disconnect(); throw error }
        infoClient.disconnect()
        var snapshot = RingHistorySnapshot(peripheralID: peripheralID, capturedAt: Date(), info: info, deviceClock: clock,
                                           clockFailure: clockFailure, histories: [])
        for command in RingReadCommand.historyCommands {
            try Task.checkCancellation()
            let client = RingClient()
            let started = Date()
            var packets: [[UInt8]] = []
            var unexpected: [[UInt8]] = []
            var unexpectedBytes = 0
            var unexpectedLimitReached = false
            var complete = false
            var failure: String?
            var collision = false
            do {
                _ = try await client.discover(duration: 1)
                try await client.connect(to: peripheralID)
                _ = try await client.readRawHistory(command, timeout: timeoutPerHistory,
                                                    maxBytes: maxBytesPerHistory, onNotification: {
                    packets.append([UInt8]($0))
                }, onUnexpectedNotification: {
                    guard $0.count <= maxBytesPerHistory - unexpectedBytes else {
                        unexpectedLimitReached = true
                        client.disconnect()
                        return
                    }
                    unexpected.append([UInt8]($0))
                    unexpectedBytes += $0.count
                })
                complete = true
            } catch {
                failure = error.localizedDescription
                if let ringError = error as? RingError, case .conflictingHistoryResponse = ringError { collision = true }
            }
            client.disconnect()
            if unexpectedLimitReached { failure = "Unexpected notification byte limit exceeded; partial capture preserved." }
            let raw = RingRawHistory(command: command.rawValue, notifications: packets)
            let capture = RingHistoryCapture(peripheralID: peripheralID, command: command, attempted: true, startedAt: started, transferComplete: complete,
                                             failure: failure, raw: raw, unexpectedNotifications: unexpected,
                                             decoded: RingHistoryCodec.decode(raw))
            snapshot.histories.append(capture)
            try onCapture?(capture)
            try Task.checkCancellation()
            if collision {
                snapshot.stopReason = failure
                for skipped in RingReadCommand.historyCommands.dropFirst(snapshot.histories.count) {
                    let raw = RingRawHistory(command: skipped.rawValue, notifications: [])
                    let capture = RingHistoryCapture(peripheralID: peripheralID, command: skipped, attempted: false, startedAt: nil,
                        transferComplete: false, failure: "Not attempted after a conflicting history response.",
                        raw: raw, unexpectedNotifications: [], decoded: RingHistoryCodec.decode(raw))
                    snapshot.histories.append(capture)
                    try onCapture?(capture)
                }
                break
            }
        }
        return snapshot
    }
}
#endif
