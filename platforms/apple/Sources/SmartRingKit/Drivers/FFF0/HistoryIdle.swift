import Foundation

/// Traffic quiescence is not an inter-app lock. An observed unfinished transfer
/// stays busy even if its sender pauses before requesting the next page.
struct RingHistoryIdleGate {
    let quietPeriod: TimeInterval
    let maxBytes: Int
    private(set) var lastActivity: Date
    private(set) var unfinished: Set<UInt8> = []
    private var receivedBytes = 0

    init(quietPeriod: TimeInterval, maxBytes: Int, startedAt: Date) {
        self.quietPeriod = quietPeriod; self.maxBytes = maxBytes; lastActivity = startedAt
    }

    mutating func observe(_ data: Data, at: Date) throws {
        guard data.count <= maxBytes - receivedBytes else { throw RingError.recordLimitExceeded }
        receivedBytes += data.count
        lastActivity = at
        guard let byte = data.first, let command = RingReadCommand(rawValue: byte), command.isHistory else { return }
        unfinished.insert(byte)
        var decoder = try RingRawHistoryDecoder(command: command, maxBytes: max(1, data.count))
        try decoder.append(data)
        if decoder.isComplete { unfinished.remove(byte) }
    }

    func isQuiet(at: Date) -> Bool {
        unfinished.isEmpty && at.timeIntervalSince(lastActivity) >= quietPeriod
    }
}
