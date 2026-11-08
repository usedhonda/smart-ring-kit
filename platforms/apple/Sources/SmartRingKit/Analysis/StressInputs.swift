import Foundation

/// One observed payload. Raw HRV/fatigue and temperature fields keep unknown units.
public struct RingStressSourceRecord: Codable, Equatable, Sendable {
    public let timestamp: RingTimestamp
    public let measurements: [RingMeasurement]
    public let series: [RingSampleSeries]
    public let rawBytes: [UInt8]
}

/// Latest measurement-time context, not proof of concurrent sensing or delivery.
public struct RingStressInputContext: Codable, Equatable, Sendable {
    public let command: UInt8
    public let recordedAt: Date
    public let ageSeconds: Double
    public let withinAgeLimit: Bool
    /// Distinct payloads at the same latest timestamp remain visible.
    public let records: [RingStressSourceRecord]
    public var isConflicting: Bool { records.count > 1 }
}

/// A descriptive heart-rate reference, not a resting-HR or stress classifier.
public struct RingHeartRateReference: Codable, Equatable, Sendable {
    public let method: String
    public let window: DateInterval
    public let sampleCount: Int
    public let excludedConflictingTimestamps: Int
    public let medianBPM: Double
    public let medianAbsoluteDeviationBPM: Double
    public let currentDifferenceBPM: Double?
    /// nil when the reference has zero dispersion or the current value is unavailable.
    public let normalizedDifference: Double?
}

public struct RingStressFeatureSet: Codable, Equatable, Sendable {
    public let at: Date
    public let timeZone: String
    public let maximumAgeSeconds: Double
    public let contexts: [RingStressInputContext]
    public let missingCommands: [UInt8]
    /// Only present with an explicit window and an explicitly selected mapping.
    public let sleep: RingSleepAnalysis?
    public let heartRateReference: RingHeartRateReference?
    public let decodingIssues: [RingDecodingIssue]
    /// A decoder input cannot establish completeness of the original radio transfer.
    public let transferCompletenessKnown: Bool
}

/// Assembles multimodal research inputs. Does not produce a stress score or probability.
public enum RingStressInputs {
    public static let contextCommands: [UInt8] = [0x55, 0x56, 0x52, 0x62, 0x54, 0x66, 0x5c]

    /// The caller supplies the historical time zone and an application age policy.
    /// Stale records are retained and marked; future records are never substituted.
    /// Optional windows must end no later than `at`; reference data is end-exclusive.
    public static func assemble(
        _ histories: [RingDecodedHistory], at: Date, timeZone: TimeZone,
        maximumAge: TimeInterval, referenceWindow: DateInterval? = nil,
        sleepWindow: DateInterval? = nil, sleepMapping: RingSleepStageMapping? = nil
    ) throws -> RingStressFeatureSet {
        guard at.timeIntervalSince1970.isFinite, maximumAge.isFinite, maximumAge >= 0,
              (referenceWindow == nil || (referenceWindow!.duration > 0 && referenceWindow!.end <= at)),
              (sleepWindow == nil || (sleepWindow!.duration > 0 && sleepWindow!.end <= at)),
              (sleepWindow == nil) == (sleepMapping == nil) else {
            throw RingError.invalidPacket("invalid stress-input age policy or analysis windows")
        }
        var groups: [UInt8: [Date: [RingStressSourceRecord]]] = [:]
        func add(_ command: UInt8, _ record: RingStressSourceRecord) throws {
            guard let date = record.timestamp.date(in: timeZone) else {
                throw RingError.invalidPacket("stress-input record has an invalid local clock")
            }
            guard date <= at else { return }
            let previous = groups[command]?[date] ?? []
            // Sequence counters change when retained records are read again.
            // Both interpreted content and payload after the header must agree.
            if !previous.contains(where: {
                $0.measurements == record.measurements && $0.series == record.series &&
                $0.rawBytes.dropFirst(3) == record.rawBytes.dropFirst(3)
            }) {
                groups[command, default: [:]][date, default: []].append(record)
            }
        }
        for history in histories where contextCommands.contains(history.command) {
            if history.command == 0x56 {
                for r in history.hrv {
                    try add(history.command, RingStressSourceRecord(timestamp: r.timestamp, measurements: [
                        RingMeasurement(name: "hrvRaw", value: Double(r.hrvRaw), unit: nil),
                        RingMeasurement(name: "nativeFatigueRaw", value: Double(r.stressRaw), unit: nil),
                        RingMeasurement(name: "heartRate", value: Double(r.heartRateBPM), unit: "bpm")
                    ], series: [], rawBytes: r.rawBytes))
                }
            } else {
                for r in history.sensors where !r.dateOnly {
                    try add(history.command, RingStressSourceRecord(timestamp: r.timestamp,
                        measurements: r.measurements, series: r.series, rawBytes: r.rawBytes))
                }
            }
        }
        let contexts = contextCommands.compactMap { command -> RingStressInputContext? in
            guard let latest = groups[command]?.keys.max(), let records = groups[command]?[latest] else { return nil }
            let age = at.timeIntervalSince(latest)
            return RingStressInputContext(command: command, recordedAt: latest, ageSeconds: age,
                                          withinAgeLimit: age <= maximumAge, records: records)
        }
        var reference: RingHeartRateReference?
        if let window = referenceWindow {
            let current = contexts.first { $0.command == 0x55 }
            let value = current.flatMap { $0.withinAgeLimit && !$0.isConflicting ? heartRate($0.records[0]) : nil }
            // A fresh current sample can precede evaluation and fall inside the reference window.
            // Keep that comparison target out of its own baseline.
            let comparisonTime = value == nil ? nil : current?.recordedAt
            let rows = (groups[0x55] ?? [:]).filter {
                $0.key >= window.start && $0.key < window.end && $0.key != comparisonTime
            }
            let values = rows.values.compactMap { records -> Double? in
                guard records.count == 1 else { return nil }
                return heartRate(records[0])
            }
            if !values.isEmpty {
                let center = median(values)
                let dispersion = median(values.map { abs($0 - center) })
                let difference = value.map { $0 - center }
                reference = RingHeartRateReference(method: "median-mad-v1", window: window,
                    sampleCount: values.count,
                    excludedConflictingTimestamps: rows.values.filter { $0.count > 1 }.count,
                    medianBPM: center, medianAbsoluteDeviationBPM: dispersion,
                    currentDifferenceBPM: difference,
                    normalizedDifference: dispersion > 0 ? difference.map { $0 / dispersion } : nil)
            }
        }
        let sleep: RingSleepAnalysis?
        if let window = sleepWindow, let mapping = sleepMapping {
            // Only samples completed by evaluation are available. The analyzer then clips
            // their overlap to the window, including samples crossing its end boundary.
            var records: [RingSleepRecord] = []
            for r in histories.flatMap(\.sleep) {
                guard let start = r.timestamp.date(in: timeZone), [1, 5].contains(r.sampleIntervalMinutes) else {
                    throw RingError.invalidPacket("stress-input sleep clock or interval")
                }
                let alignedStart = floor(start.timeIntervalSince1970 / 60) * 60
                let completed = floor((at.timeIntervalSince1970 - alignedStart) / Double(r.sampleIntervalMinutes * 60))
                let count = Int(min(Double(r.categoryValues.count), max(0, completed)))
                guard count > 0 else { continue }
                records.append(RingSleepRecord(timestamp: r.timestamp, sampleIntervalMinutes: r.sampleIntervalMinutes,
                    categoryValues: Array(r.categoryValues.prefix(count)), rawBytes: r.rawBytes))
            }
            sleep = try RingSleepAnalyzer.analyze(records, timeZone: timeZone, mapping: mapping, window: window)
        } else { sleep = nil }
        return RingStressFeatureSet(at: at, timeZone: timeZone.identifier, maximumAgeSeconds: maximumAge,
            contexts: contexts, missingCommands: contextCommands.filter { command in !contexts.contains { $0.command == command } },
            sleep: sleep, heartRateReference: reference, decodingIssues: histories.flatMap(\.issues),
            transferCompletenessKnown: false)
    }

    private static func heartRate(_ record: RingStressSourceRecord) -> Double? {
        guard let value = record.measurements.first(where: { $0.name == "heartRate" && $0.unit == "bpm" })?.value,
              value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? sorted[middle - 1] / 2 + sorted[middle] / 2 : sorted[middle]
    }
}
