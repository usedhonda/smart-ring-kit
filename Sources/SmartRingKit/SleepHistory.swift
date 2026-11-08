import Foundation

/// SDK-labelled sleep history. Category meanings (including REM/deep/light) are
/// not established; no sleep score or vendor-app equivalence is inferred.
public struct RingSleepRecord: Codable, Equatable, Sendable {
    public let timestamp: RingTimestamp
    public let sampleIntervalMinutes: Int
    public let categoryValues: [UInt8]
    public let rawBytes: [UInt8]
}

/// Implements the SDK's 130-byte/one-minute and 34-byte/five-minute layouts.
/// No hardware capture of these layouts on the target ring is distributed.
public struct RingSleepHistoryDecoder: Sendable {
    public private(set) var records: [RingSleepRecord] = []
    public private(set) var isComplete = false
    private let maxRecords: Int

    public init(maxRecords: Int = 10_000) { self.maxRecords = maxRecords }

    public mutating func append(_ data: Data) throws {
        guard !isComplete else { throw RingError.invalidPacket("data after sleep terminator") }
        var b = [UInt8](data)
        let trailingMarkerFits = b.count == 2 || b.count == 132 || (b.count > 2 && (b.count - 2).isMultiple(of: 34))
        let end = trailingMarkerFits && b.suffix(2) == [0x53, 0xff]
        if end { b.removeLast(2) }
        if b.isEmpty, end { isComplete = true; return }
        let width: Int
        let interval: Int
        if b.count == 130 { width = 130; interval = 1 }
        else if !b.isEmpty, b.count.isMultiple(of: 34) { width = 34; interval = 5 }
        else { throw RingError.invalidPacket("unsupported sleep notification length") }
        var batch: [RingSleepRecord] = []
        for offset in stride(from: 0, to: b.count, by: width) {
            guard records.count + batch.count < maxRecords else { throw RingError.recordLimitExceeded }
            let row = Array(b[offset..<(offset + width)])
            guard row[0] == 0x53, Int(row[9]) <= width - 10 else {
                throw RingError.invalidPacket("sleep header or category count")
            }
            let stamp = try RingPacketDecoder.timestamp(Array(row[3...8]))
            let values = Array(row[10..<(10 + Int(row[9]))])
            batch.append(RingSleepRecord(timestamp: stamp, sampleIntervalMinutes: interval,
                                         categoryValues: values, rawBytes: row))
        }
        records.append(contentsOf: batch)
        isComplete = end
    }
}

/// Uninterpreted notifications for SDK-defined history commands. These additional
/// device responses are experimental; returned bytes are not validated health metrics.
public struct RingRawHistory: Codable, Equatable, Sendable {
    public let command: UInt8
    public let notifications: [[UInt8]]
}

public struct RingRawHistoryDecoder: Sendable {
    public private(set) var isComplete = false
    public private(set) var notifications: [[UInt8]] = []
    public private(set) var byteCount = 0
    private let command: RingReadCommand
    private let maxBytes: Int

    public init(command: RingReadCommand, maxBytes: Int = 2_000_000) throws {
        guard command.isHistory, maxBytes > 0 else {
            throw RingError.invalidPacket("a history command and positive byte limit are required")
        }
        self.command = command
        self.maxBytes = maxBytes
    }

    public var result: RingRawHistory { RingRawHistory(command: command.rawValue, notifications: notifications) }

    public mutating func append(_ data: Data) throws {
        guard !isComplete, data.count >= 2, data.first == command.rawValue else {
            throw RingError.invalidPacket("raw history header, length or completed transfer")
        }
        guard data.count <= maxBytes - byteCount else {
            throw RingError.invalidPacket("raw history byte limit exceeded")
        }
        let b = [UInt8](data)
        notifications.append(b)
        byteCount += b.count
        isComplete = b.suffix(2) == [command.rawValue, 0xff]
    }
}
