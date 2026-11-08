import Foundation

public enum RingError: Error, LocalizedError, Equatable {
    case busy, disconnected, cancelled, timedOut, bluetoothUnavailable
    case unsupportedDevice, invalidPacket(String), recordLimitExceeded
    case transport(String)
    case conflictingHistoryResponse(expected: UInt8, received: UInt8)

    public var errorDescription: String? {
        switch self {
        case .busy: return "Another ring operation is in progress."
        case .disconnected: return "The ring is not connected."
        case .cancelled: return "The ring operation was cancelled."
        case .timedOut: return "The ring operation timed out. Reconnect before retrying."
        case .bluetoothUnavailable: return "Bluetooth is unavailable or access was denied."
        case .unsupportedDevice: return "The expected ring service or characteristics are missing."
        case .invalidPacket(let reason): return "Invalid ring packet: \(reason)"
        case .recordLimitExceeded: return "The history exceeded the configured record limit."
        case .transport(let reason): return "Bluetooth error: \(reason)"
        case .conflictingHistoryResponse(let expected, let received):
            return "Received history \(received) while reading \(expected). Another reader may be active; pause other ring sync clients before retrying."
        }
    }
}

/// Non-destructive requests. Sleep and other additional histories are based on
/// the reference SDK; hardware support must be verified per device/firmware.
public enum RingReadCommand: UInt8, Sendable, CaseIterable, Codable {
    case firmware = 0x27
    case battery = 0x13
    case hrvHistory = 0x56
    case sleepHistory = 0x53
    case heartRateHistory = 0x54
    case temperatureHistory = 0x62
    case oxygenHistory = 0x66
    case activityHistory = 0x52
    case dailyActivityHistory = 0x51
    case spotHeartRateHistory = 0x55
    case manualOxygenHistory = 0x67
    case exerciseHistory = 0x5c
    case deviceClock = 0x41

    var isHistory: Bool { self != .firmware && self != .battery && self != .deviceClock }

    public static var historyCommands: [RingReadCommand] { allCases.filter(\.isHistory) }

    public var packet: Data {
        readPacket(continuing: false)
    }

    func readPacket(continuing: Bool) -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = rawValue
        bytes[1] = continuing && isHistory ? 2 : 0
        // History mode 0x00 requests existing records. No delete/configuration API.
        bytes[15] = bytes.prefix(15).reduce(0, &+)
        return Data(bytes)
    }
}

public struct RingInfo: Codable, Equatable, Sendable {
    public let firmware: String
    public let batteryPercent: Int
}

/// Ring-local wall-clock time. The protocol does not carry a time zone.
public struct RingTimestamp: Codable, Equatable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let hour: Int
    public let minute: Int
    public let second: Int

    /// The caller must choose the time zone used when the ring recorded this value.
    public func date(in timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        ))
    }
}

/// Device/SDK-labelled values, without inferred HRV units or stress interpretation.
public struct RingHRVRecord: Codable, Equatable, Sendable {
    public let timestamp: RingTimestamp
    public let hrvRaw: UInt8
    public let heartRateBPM: UInt8
    public let stressRaw: UInt8
    /// Uninterpreted record bytes, retained for future protocol research.
    public let rawBytes: [UInt8]
}

public enum RingPacketDecoder {
    public static func firmware(_ data: Data) throws -> String {
        let b = [UInt8](data)
        guard b.count >= 5, b[0] == RingReadCommand.firmware.rawValue else {
            throw RingError.invalidPacket("firmware header or length")
        }
        return b[1...4].map { String($0, radix: 16, uppercase: true) }.joined(separator: ".")
    }

    public static func battery(_ data: Data) throws -> Int {
        let b = [UInt8](data)
        guard b.count >= 2, b[0] == RingReadCommand.battery.rawValue, b[1] <= 100 else {
            throw RingError.invalidPacket("battery header, length, or percentage")
        }
        return Int(b[1])
    }

    public static func hrvRecord(_ data: Data) throws -> RingHRVRecord {
        let b = [UInt8](data)
        guard b.count == 15, b[0] == RingReadCommand.hrvHistory.rawValue else {
            throw RingError.invalidPacket("HRV record header or length")
        }
        let t = try timestamp(Array(b[3...8]))
        return RingHRVRecord(timestamp: t, hrvRaw: b[9], heartRateBPM: b[11],
                             stressRaw: b[12], rawBytes: b)
    }

    static func timestamp(_ b: [UInt8]) throws -> RingTimestamp {
        guard b.count == 6 else { throw RingError.invalidPacket("timestamp length") }
        func bcd(_ byte: UInt8) throws -> Int {
            guard byte >> 4 < 10, byte & 0x0f < 10 else {
                throw RingError.invalidPacket("non-BCD timestamp")
            }
            return Int(byte >> 4) * 10 + Int(byte & 0x0f)
        }
        let t = try RingTimestamp(year: 2000 + bcd(b[0]), month: bcd(b[1]), day: bcd(b[2]),
                                  hour: bcd(b[3]), minute: bcd(b[4]), second: bcd(b[5]))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = t.date(in: calendar.timeZone) else {
            throw RingError.invalidPacket("invalid calendar date")
        }
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard parts.year == t.year, parts.month == t.month, parts.day == t.day,
              parts.hour == t.hour, parts.minute == t.minute, parts.second == t.second else {
            throw RingError.invalidPacket("out-of-range timestamp")
        }
        return t
    }
}

/// Decodes the observed record-aligned notifications and trailing [0x56, 0xff].
/// Rejects incomplete records rather than silently dropping a truncated transfer.
public struct RingHistoryDecoder: Sendable {
    public private(set) var records: [RingHRVRecord] = []
    public private(set) var isComplete = false
    private let maxRecords: Int

    public init(maxRecords: Int = 10_000) { self.maxRecords = maxRecords }

    public mutating func append(_ data: Data) throws {
        guard !isComplete else { throw RingError.invalidPacket("data after history terminator") }
        let bytes = [UInt8](data)
        let hasTerminator = bytes.count % 15 == 2 && bytes.suffix(2) == [0x56, 0xff]
        let recordBytes = bytes.count - (hasTerminator ? 2 : 0)
        guard !bytes.isEmpty, recordBytes % 15 == 0 else {
            throw RingError.invalidPacket("truncated history notification or invalid terminator")
        }
        // A 0xff in a record's final byte is not an end marker.
        var batch: [RingHRVRecord] = []
        for offset in stride(from: 0, to: recordBytes, by: 15) {
            guard records.count + batch.count < maxRecords else { throw RingError.recordLimitExceeded }
            batch.append(try RingPacketDecoder.hrvRecord(Data(bytes[offset..<(offset + 15)])))
        }
        records.append(contentsOf: batch)
        isComplete = hasTerminator
    }
}
