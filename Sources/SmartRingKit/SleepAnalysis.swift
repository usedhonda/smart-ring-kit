import Foundation

public enum RingSleepStage: String, Codable, CaseIterable, Sendable {
    case awake, light, deep, rem, unknown, missing
}

/// A mapping is a device-specific interpretation, not a new medical classifier.
public struct RingSleepStageMapping: Sendable {
    public let name: String
    public let values: [UInt8: RingSleepStage]

    public init(name: String, values: [UInt8: RingSleepStage]) {
        self.name = name
        self.values = values
    }

    /// Matched against stage-duration totals on the vendor app for this firmware.
    /// Codes 10/11 and future values intentionally stay unknown.
    public static let issinFirmware0750 = RingSleepStageMapping(
        name: "issin-0.7.5.0-observed", values: [1: .deep, 2: .light, 3: .rem, 5: .awake]
    )
}

public struct RingSleepInterval: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let stage: RingSleepStage
    public let rawValues: [UInt8]
    public let conflicting: Bool
}

public struct RingSleepStageDuration: Codable, Equatable, Sendable {
    public let stage: RingSleepStage
    public let seconds: Double
}

public struct RingSleepAnalysis: Codable, Equatable, Sendable {
    public let mapping: String
    public let timeZone: String
    public let intervals: [RingSleepInterval]
    public let durations: [RingSleepStageDuration]
    public let duplicateSamples: Int
    public let conflictingMinutes: Int
    public let minuteAligned: Bool
}

public enum RingSleepAnalyzer {
    /// Uses minute bins because the protocol's resolution is one/five minutes.
    /// The source records retain their seconds. Matching overlap is counted once;
    /// conflicting overlap stays unknown. Missing coverage never becomes awake.
    /// Pass a window to summarize one night; no night/session boundaries are guessed.
    public static func analyze(_ records: [RingSleepRecord], timeZone: TimeZone,
                               mapping: RingSleepStageMapping,
                               window: DateInterval? = nil) throws -> RingSleepAnalysis {
        struct Bin { var values: Set<UInt8> }
        var bins: [Int64: Bin] = [:]
        var duplicates = 0
        for record in records {
            guard [1, 5].contains(record.sampleIntervalMinutes),
                  let rawStart = record.timestamp.date(in: timeZone) else {
                throw RingError.invalidPacket("sleep clock or sample interval")
            }
            let firstMinute = Int64(floor(rawStart.timeIntervalSince1970 / 60))
            for (index, value) in record.categoryValues.enumerated() {
                for minute in 0..<record.sampleIntervalMinutes {
                    let key = firstMinute + Int64(index * record.sampleIntervalMinutes + minute)
                    if bins[key]?.values.contains(value) == true {
                        let start = Date(timeIntervalSince1970: Double(key) * 60)
                        if window.map({ start < $0.end && start.addingTimeInterval(60) > $0.start }) ?? true {
                            duplicates += 1
                        }
                    }
                    bins[key, default: Bin(values: [])].values.insert(value)
                }
            }
        }
        guard let first = bins.keys.min() else {
            return RingSleepAnalysis(mapping: mapping.name, timeZone: timeZone.identifier,
                                     intervals: [], durations: [], duplicateSamples: 0,
                                     conflictingMinutes: 0, minuteAligned: true)
        }
        // Keep work proportional to samples, even when retained nights are years apart.
        let keys = bins.keys.sorted()
        var pieces: [RingSleepInterval] = []
        var conflictingMinutes = 0
        func add(start: Date, end: Date, stage: RingSleepStage, values: [UInt8], conflict: Bool) {
            let lo = max(start, window?.start ?? start)
            let hi = min(end, window?.end ?? end)
            guard lo < hi else { return }
            if let old = pieces.last, old.end == lo, old.stage == stage,
               old.rawValues == values, old.conflicting == conflict {
                pieces[pieces.count - 1] = RingSleepInterval(start: old.start, end: hi, stage: stage,
                                                           rawValues: values, conflicting: conflict)
            } else {
                pieces.append(RingSleepInterval(start: lo, end: hi, stage: stage,
                                                rawValues: values, conflicting: conflict))
            }
        }
        var previous = first
        for key in keys {
            if key > previous {
                add(start: Date(timeIntervalSince1970: Double(previous) * 60),
                    end: Date(timeIntervalSince1970: Double(key) * 60), stage: .missing, values: [], conflict: false)
            }
            let values = bins[key]!.values.sorted()
            let conflict = values.count > 1
            let stage = conflict ? RingSleepStage.unknown : mapping.values[values[0]] ?? .unknown
            let start = Date(timeIntervalSince1970: Double(key) * 60)
            let end = start.addingTimeInterval(60)
            if conflict, window == nil || (start < window!.end && end > window!.start) { conflictingMinutes += 1 }
            add(start: start, end: end, stage: stage, values: values, conflict: conflict)
            previous = key + 1
        }
        let durations = RingSleepStage.allCases.map { stage in
            RingSleepStageDuration(stage: stage, seconds: pieces.filter { $0.stage == stage }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) })
        }
        return RingSleepAnalysis(mapping: mapping.name, timeZone: timeZone.identifier, intervals: pieces,
                                 durations: durations, duplicateSamples: duplicates,
                                 conflictingMinutes: conflictingMinutes, minuteAligned: true)
    }
}
