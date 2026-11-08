import Foundation

public struct RingMeasurement: Codable, Equatable, Sendable {
    public let name: String
    public let value: Double
    /// nil means the physical unit has not been established, not unitless.
    public let unit: String?
}

public struct RingSampleSeries: Codable, Equatable, Sendable {
    public let name: String
    public let values: [UInt8]
    public let unit: String?
    /// Unknown sampling intervals remain nil; array indices are not timestamps.
    public let intervalSeconds: Int?
}

public struct RingSensorRecord: Codable, Equatable, Sendable {
    public let timestamp: RingTimestamp
    public let dateOnly: Bool
    public let format: String
    public let measurements: [RingMeasurement]
    public let series: [RingSampleSeries]
    public let rawBytes: [UInt8]
}

public struct RingDecodingIssue: Codable, Equatable, Sendable {
    public let notificationIndex: Int
    public let reason: String
}

/// A recognized record boundary whose fields are not yet established. It is not
/// silently coerced into a legacy layout or labelled as a valid measurement.
public struct RingOpaqueRecord: Codable, Equatable, Sendable {
    public let format: String
    public let rawBytes: [UInt8]
}

/// Diagnostics for the observed record counters in header byte 1 (daily) or
/// bytes 1-2 (other known layouts). Gaps are not silently called complete data.
/// Counter interpretation is observed on the tested firmware, not universal.
public struct RingHistoryIntegrity: Codable, Equatable, Sendable {
    public let records: Int
    public let firstSequence: Int
    public let lastSequence: Int
    public let missingSequenceValues: Int
    public let duplicateTransitions: Int
    public let outOfOrderTransitions: Int
    public let counterBits: Int

    public var isContiguous: Bool {
        missingSequenceValues == 0 && duplicateTransitions == 0 && outOfOrderTransitions == 0
    }

    static func analyze(_ rows: [[UInt8]], daily: Bool) -> RingHistoryIntegrity? {
        let ids = rows.map { Int($0[1]) + (daily ? 0 : Int($0[2]) << 8) }
        guard let first = ids.first, let last = ids.last else { return nil }
        let modulus = daily ? 256 : 65_536
        var missing = 0, duplicates = 0, backwards = 0
        for (a, b) in zip(ids, ids.dropFirst()) {
            let delta = (b - a + modulus) % modulus
            if delta == 0 { duplicates += 1 }
            else if delta > modulus / 2 { backwards += 1 }
            else if delta > 1 { missing += delta - 1 }
        }
        return RingHistoryIntegrity(records: ids.count, firstSequence: first, lastSequence: last,
                                    missingSequenceValues: missing, duplicateTransitions: duplicates,
                                    outOfOrderTransitions: backwards, counterBits: daily ? 8 : 16)
    }
}

/// Parsed values plus every undecodable notification. A complete radio transfer
/// does not imply complete interpretation: inspect issues and unparsedNotifications.
public struct RingDecodedHistory: Codable, Equatable, Sendable {
    public let command: UInt8
    public var hrv: [RingHRVRecord] = []
    public var sleep: [RingSleepRecord] = []
    public var sensors: [RingSensorRecord] = []
    public var opaqueRecords: [RingOpaqueRecord] = []
    public var integrity: RingHistoryIntegrity?
    public var issues: [RingDecodingIssue] = []
    public var unparsedNotifications: [[UInt8]] = []
}

public enum RingHistoryCodec {
    public static func decode(_ history: RingRawHistory) -> RingDecodedHistory {
        var result = RingDecodedHistory(command: history.command)
        var sequenceRows: [[UInt8]] = []
        guard let command = RingReadCommand(rawValue: history.command), command.isHistory else {
            result.issues.append(RingDecodingIssue(notificationIndex: 0, reason: "Unknown history command"))
            result.unparsedNotifications = history.notifications
            return result
        }
        for (index, bytes) in history.notifications.enumerated() {
            do {
                switch command {
                case .sleepHistory:
                    var parser = RingSleepHistoryDecoder()
                    try parser.append(Data(bytes))
                    result.sleep += parser.records
                    sequenceRows += parser.records.map(\.rawBytes)
                case .hrvHistory:
                    var parser = RingHistoryDecoder()
                    try parser.append(Data(bytes))
                    result.hrv += parser.records
                    sequenceRows += parser.records.map(\.rawBytes)
                case .manualOxygenHistory:
                    var body = bytes
                    if body.count % 31 == 2, body.suffix(2) == [0x67, 0xff] { body.removeLast(2) }
                    if !body.isEmpty, body.count.isMultiple(of: 31),
                       stride(from: 0, to: body.count, by: 31).allSatisfy({ body[$0] == 0x67 }) {
                        let records = stride(from: 0, to: body.count, by: 31).map {
                            RingOpaqueRecord(format: "fff0-67-31-uninterpreted", rawBytes: Array(body[$0..<($0 + 31)]))
                        }
                        result.opaqueRecords += records
                        sequenceRows += records.map(\.rawBytes)
                    } else {
                        let records = try sensorRecords(bytes, command: command)
                        result.sensors += records
                        sequenceRows += records.map(\.rawBytes)
                    }
                default:
                    let records = try sensorRecords(bytes, command: command)
                    result.sensors += records
                    sequenceRows += records.map(\.rawBytes)
                }
            } catch {
                result.issues.append(RingDecodingIssue(notificationIndex: index, reason: error.localizedDescription))
                result.unparsedNotifications.append(bytes)
            }
        }
        result.integrity = RingHistoryIntegrity.analyze(sequenceRows, daily: command == .dailyActivityHistory)
        return result
    }

    private static func sensorRecords(_ input: [UInt8], command: RingReadCommand) throws -> [RingSensorRecord] {
        guard input.first == command.rawValue else { throw RingError.invalidPacket("sensor command") }
        if input == [command.rawValue, 0xff] { return [] }
        let widths: [Int]
        switch command {
        case .heartRateHistory: widths = [24]
        case .spotHeartRateHistory, .oxygenHistory, .manualOxygenHistory: widths = [10]
        case .temperatureHistory: widths = [15, 11]
        case .activityHistory, .exerciseHistory: widths = [25]
        case .dailyActivityHistory: widths = [26, 27]
        default: throw RingError.invalidPacket("unsupported sensor layout")
        }
        var candidates: [(Int, [UInt8])] = []
        for width in widths {
            var bytes = input
            if bytes.count % width == 2, bytes.suffix(2) == [command.rawValue, 0xff] { bytes.removeLast(2) }
            if !bytes.isEmpty, bytes.count.isMultiple(of: width),
               stride(from: 0, to: bytes.count, by: width).allSatisfy({ bytes[$0] == command.rawValue }) {
                candidates.append((width, bytes))
            }
        }
        guard candidates.count == 1, let (width, bytes) = candidates.first else {
            throw RingError.invalidPacket("unknown or ambiguous sensor record width")
        }
        return try stride(from: 0, to: bytes.count, by: width).map { offset in
            let row = Array(bytes[offset..<(offset + width)])
            let daily = command == .dailyActivityHistory
            let stamp = try RingPacketDecoder.timestamp(daily ? Array(row[2...4]) + [0, 0, 0] : Array(row[3...8]))
            var values: [RingMeasurement] = []
            var series: [RingSampleSeries] = []
            func add(_ name: String, _ value: Double, _ unit: String? = nil) {
                values.append(RingMeasurement(name: name, value: value, unit: unit))
            }
            func integer(_ offset: Int, _ count: Int) -> UInt32 {
                (0..<count).reduce(0) { $0 | UInt32(row[offset + $1]) << (8 * $1) }
            }
            switch command {
            case .spotHeartRateHistory:
                add("heartRate", Double(row[9]), "bpm")
            case .oxygenHistory, .manualOxygenHistory:
                add("oxygenSaturation", Double(row[9]), "%")
            case .heartRateHistory:
                series.append(RingSampleSeries(name: "heartRate", values: Array(row[9...23]), unit: "bpm", intervalSeconds: nil))
            case .temperatureHistory:
                // SDK defines bytes 9-10 as unsigned tenths of its temperature unit.
                // Observed firmware extends the 11-byte record to 15 bytes. Preserve
                // extra fields; neither historical unit nor sensor role is inferred.
                add("temperatureSDKValue", Double(integer(9, 2)) / 10)
                add("temperatureRaw", Double(integer(9, 2)))
            case .activityHistory:
                add("steps", Double(integer(9, 2)), "count")
                add("caloriesSDKValue", Double(integer(11, 2)) / 100)
                add("distanceSDKValue", Double(integer(13, 2)) / 100)
                series.append(RingSampleSeries(name: "steps", values: Array(row[15...24]), unit: "count", intervalSeconds: nil))
            case .dailyActivityHistory:
                add("steps", Double(integer(5, 4)), "count")
                add("exerciseTimeSDKValue", Double(integer(9, 4)))
                add("distanceSDKValue", Double(integer(13, 4)) / 100)
                add("caloriesSDKValue", Double(integer(17, 4)) / 100)
                add("goalRaw", Double(integer(21, width == 26 ? 1 : 2)))
                add("activeTimeSDKValue", Double(integer(width - 4, 4)))
            case .exerciseHistory:
                add("activityModeRaw", Double(row[9]))
                add("heartRate", Double(row[10]), "bpm")
                add("activeTimeSDKValue", Double(integer(11, 2)))
                add("steps", Double(integer(13, 2)), "count")
                add("paceMinutesPart", Double(row[15]))
                add("paceSecondsPart", Double(row[16]))
                let calories = Float(bitPattern: integer(17, 4))
                let distance = Float(bitPattern: integer(21, 4))
                guard calories.isFinite, distance.isFinite else { throw RingError.invalidPacket("non-finite exercise value") }
                add("caloriesSDKValue", Double(calories))
                add("distanceSDKValue", Double(distance))
            default: break
            }
            return RingSensorRecord(timestamp: stamp, dateOnly: daily,
                                    format: "fff0-\(String(command.rawValue, radix: 16))-\(width)",
                                    measurements: values, series: series, rawBytes: row)
        }
    }
}
