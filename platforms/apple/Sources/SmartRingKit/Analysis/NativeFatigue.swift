import Foundation

/// An explicitly time-stamped, available input snapshot. Never put the target fatigue in values.
public struct RingFatigueSample: Codable, Equatable, Sendable {
    public let measuredAt: Date
    public let availableAt: Date
    public let values: [String: Double]
    public init(measuredAt: Date, availableAt: Date, values: [String: Double]) {
        self.measuredAt = measuredAt; self.availableAt = availableAt; self.values = values
    }

    /// Caller must assemble only data received by availableAt. Entire 0x56 is excluded
    /// so the current label, HRV and its update timing cannot leak into predictions.
    public init(inputs: RingStressFeatureSet, availableAt: Date) {
        var values: [String: Double] = [:]
        for (command, name, key) in [(UInt8(0x55), "heartRate", "heartRateBPM"),
                                     (0x52, "steps", "activitySteps"),
                                     (0x62, "temperatureSDKValue", "temperatureSDKValue")] {
            if let c = inputs.contexts.first(where: { $0.command == command }), c.withinAgeLimit,
               c.records.count == 1, let record = c.records.first,
               let v = record.measurements.first(where: { $0.name == name })?.value {
                values[key] = v
            }
        }
        let observedStages: [RingSleepStage] = [.deep, .light, .rem, .awake]
        if let sleep = inputs.sleep, sleep.conflictingMinutes == 0,
           sleep.intervals.contains(where: { observedStages.contains($0.stage) && !$0.conflicting && $0.start < $0.end }) {
            for stage in observedStages {
                values["sleep\(stage.rawValue.capitalized)ObservedSeconds"] = sleep.durations.first { $0.stage == stage }?.seconds ?? 0
            }
        }
        self.init(measuredAt: inputs.at, availableAt: availableAt, values: values)
    }
}

/// The native 0x56 fatigue byte, not a Welly or psychological stress score.
public struct RingNativeFatigueAnchor: Codable, Equatable, Sendable {
    public let measuredAt: Date
    public let availableAt: Date
    public let value: UInt8
    public init(measuredAt: Date, availableAt: Date, value: UInt8) {
        self.measuredAt = measuredAt; self.availableAt = availableAt; self.value = value
    }
}

public enum RingFatigueCorrection: String, Codable, Sendable {
    case carryForward, unanchored, fullResidual, learnedDecay
}

/// Engineering policies for an unvalidated experiment, not physiological thresholds.
public struct RingFatigueConfiguration: Codable, Sendable {
    public var featureNames: [String]
    public var correction: RingFatigueCorrection
    public var minimumTrainingSamples: Int
    public var maximumAnchorAgeSeconds: Double
    public var maximumSampleAgeSeconds: Double
    public var trainingWindowSeconds: Double
    public var ridgePenalty: Double
    public init(correction: RingFatigueCorrection, featureNames: [String] = ["heartRateBPM"],
                minimumTrainingSamples: Int = 24, maximumAnchorAgeSeconds: Double = 7200,
                maximumSampleAgeSeconds: Double = 600, trainingWindowSeconds: Double = 28 * 86400,
                ridgePenalty: Double = 1) {
        self.correction = correction; self.featureNames = featureNames
        self.minimumTrainingSamples = minimumTrainingSamples; self.maximumAnchorAgeSeconds = maximumAnchorAgeSeconds
        self.maximumSampleAgeSeconds = maximumSampleAgeSeconds; self.trainingWindowSeconds = trainingWindowSeconds
        self.ridgePenalty = ridgePenalty
    }
}

public struct RingFatigueEstimate: Codable, Sendable {
    public let at: Date
    public let asOf: Date
    public let status: String
    public let value: Double?
    public let reason: String?
    public let anchorTime: Date?
    public let anchorAvailableAt: Date?
    public let anchorValue: UInt8?
    public let anchorAgeSeconds: Double?
    public let sampleTime: Date?
    public let method: RingFatigueCorrection
    public let modelVersion: String
    public let trainingBefore: Date
    public let trainingSamples: Int
    public let residualPairs: Int
    public let retentionPerHour: Double?
    public let validationStatus: String
}

/// Experimental native-fatigue proxy. No background task, BLE write, clinical scale or trained weights.
public struct RingFatigueEstimator: Sendable {
    public static let modelVersion = "native-fatigue-ridge-decay-v2"
    public let configuration: RingFatigueConfiguration
    public let trainingBefore: Date
    public let trainedAsOf: Date
    public let trainingSamples: Int
    public let residualPairs: Int
    public let retentionPerHour: Double?
    private let fit: Regression?
    private struct Point { let x: [Double]; let y: Double }
    private struct Regression: Sendable {
        let means: [Double], scales: [Double], lower: [Double], upper: [Double], coefficients: [Double]
        func accepts(_ x: [Double]) -> Bool { x.indices.allSatisfy { x[$0] >= lower[$0] && x[$0] <= upper[$0] } }
        func predict(_ x: [Double]) -> Double {
            coefficients[0] + x.indices.reduce(0) { $0 + coefficients[$1 + 1] * (x[$1] - means[$1]) / scales[$1] }
        }
    }

    /// Fits only records measured strictly before before and received by asOf.
    /// Residual decay is fit from prior-UTC-day predictions, not in-sample residuals.
    public init(samples: [RingFatigueSample], anchors: [RingNativeFatigueAnchor],
                before: Date, asOf: Date, configuration c: RingFatigueConfiguration) throws {
        let allowed: Set<String> = ["heartRateBPM", "activitySteps", "temperatureSDKValue",
                                   "sleepDeepObservedSeconds", "sleepLightObservedSeconds",
                                   "sleepRemObservedSeconds", "sleepAwakeObservedSeconds"]
        guard Self.valid(before), Self.valid(asOf), before <= asOf,
              !c.featureNames.isEmpty, Set(c.featureNames).count == c.featureNames.count,
              Set(c.featureNames).isSubset(of: allowed), c.minimumTrainingSamples >= c.featureNames.count + 2,
              [c.maximumAnchorAgeSeconds, c.maximumSampleAgeSeconds, c.trainingWindowSeconds, c.ridgePenalty].allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw RingError.invalidPacket("invalid fatigue training policy")
        }
        try Self.validate(samples, anchors)
        configuration = c; trainingBefore = before; trainedAsOf = asOf
        let visibleAnchors = Self.trainingAnchors(anchors, before: before, asOf: asOf, c: c)
        let points = Self.trainingPoints(samples, anchors: visibleAnchors, c: c)
        trainingSamples = points.count
        fit = points.count >= c.minimumTrainingSamples ? Self.regress(points, c.ridgePenalty) : nil
        var pairs: [(hours: Double, previous: Double, current: Double)] = []
        if c.correction == .learnedDecay {
            var cachedDay: Double?, previousFit: Regression?
            for target in visibleAnchors {
                let day = floor(target.measuredAt.timeIntervalSince1970 / 86400) * 86400
                if cachedDay != day {
                    let cutoff = Date(timeIntervalSince1970: day)
                    // Reconstruct the historical knowledge state before resolving conflicts.
                    // A later revision must not change a model frozen at this cutoff.
                    let pastAnchors = Self.trainingAnchors(anchors, before: cutoff, asOf: cutoff, c: c)
                    let past = Self.trainingPoints(samples, anchors: pastAnchors, c: c)
                    previousFit = past.count >= c.minimumTrainingSamples ? Self.regress(past, c.ridgePenalty) : nil
                    cachedDay = day
                }
                guard let f = previousFit,
                      let current = Self.sample(samples, at: target.measuredAt, asOf: target.measuredAt, c: c),
                      let x = Self.vector(current, c), f.accepts(x) else { continue }
                // Hide the target event and select the anchor that a real-time query
                // could actually use, including intervening conflicts or missing inputs.
                let known = anchors.filter { $0.measuredAt < target.measuredAt && $0.availableAt <= target.measuredAt }
                guard let latestTime = known.map(\.measuredAt).max(),
                      latestTime.timeIntervalSince1970 >= day,
                      before.timeIntervalSince(latestTime) <= c.trainingWindowSeconds else { continue }
                let latest = known.filter { $0.measuredAt == latestTime }
                guard Set(latest.map(\.value)).count == 1,
                      let anchor = latest.min(by: { $0.availableAt < $1.availableAt }) else { continue }
                let age = target.measuredAt.timeIntervalSince(anchor.measuredAt)
                guard age > 0, age <= c.maximumAnchorAgeSeconds,
                      let old = Self.sample(samples, at: anchor.measuredAt, asOf: anchor.availableAt, c: c),
                      let ax = Self.vector(old, c), f.accepts(ax) else { continue }
                // Both residuals use this day's same frozen model. Cross-day pairs
                // cannot mistake a model refit for decay in the native signal.
                let previous = Double(anchor.value) - f.predict(ax)
                let currentError = Double(target.value) - f.predict(x)
                guard previous.isFinite, currentError.isFinite else { continue }
                pairs.append((age / 3600, previous, currentError))
            }
        }
        residualPairs = pairs.count
        // Fixed numerical grid, fit on development data only. rho=0 means no correction
        // after the exact anchor instant. Negative serial dependence is not represented.
        if pairs.contains(where: { abs($0.previous) > 1e-12 }) {
            let candidates = (0...100).map { index -> (rho: Double, loss: Double) in
                let rho = Double(index) / 100
                let loss = pairs.reduce(0.0) { sum, pair in
                    let e = pair.current - pow(rho, pair.hours) * pair.previous
                    return sum + e * e
                }
                return (rho, loss)
            }
            retentionPerHour = candidates.filter { $0.loss.isFinite }.min { $0.loss < $1.loss }?.rho
        } else { retentionPerHour = nil }
    }

    /// asOf is actual knowledge time; at is measurement time. Later arrivals require
    /// a separate revision; this pure function never overwrites earlier results.
    public func estimate(samples: [RingFatigueSample], anchors: [RingNativeFatigueAnchor],
                         at: Date, asOf: Date) throws -> RingFatigueEstimate {
        try Self.validate(samples, anchors)
        guard Self.valid(at), Self.valid(asOf), at <= asOf, trainingBefore <= at, trainedAsOf <= asOf else {
            throw RingError.invalidPacket("fatigue query precedes model availability or has invalid time")
        }
        let visible = anchors.filter { $0.measuredAt <= at && $0.availableAt <= asOf }
        let time = visible.map(\.measuredAt).max()
        let latest = visible.filter { $0.measuredAt == time }
        let a = latest.min { $0.availableAt < $1.availableAt }
        let sample = Self.sample(samples, at: at, asOf: asOf, c: configuration)
        func result(_ status: String, _ value: Double? = nil, _ reason: String? = nil) -> RingFatigueEstimate {
            RingFatigueEstimate(at: at, asOf: asOf, status: status, value: value, reason: reason,
                anchorTime: time, anchorAvailableAt: a?.availableAt, anchorValue: Set(latest.map(\.value)).count == 1 ? a?.value : nil,
                anchorAgeSeconds: time.map { at.timeIntervalSince($0) }, sampleTime: sample?.measuredAt,
                method: configuration.correction, modelVersion: Self.modelVersion, trainingBefore: trainingBefore,
                trainingSamples: trainingSamples, residualPairs: residualPairs, retentionPerHour: retentionPerHour,
                validationStatus: "experimental_unvalidated")
        }
        guard let a else { return result("unavailable", nil, "no_available_anchor") }
        guard Set(latest.map(\.value)).count == 1 else { return result("unavailable", nil, "conflicting_anchor") }
        if a.measuredAt == at { return result("native_observed", Double(a.value)) }
        let age = at.timeIntervalSince(a.measuredAt)
        guard age <= configuration.maximumAnchorAgeSeconds else { return result("unavailable", nil, "stale_anchor") }
        if configuration.correction == .carryForward { return result("estimated", Double(a.value)) }
        guard let fit else {
            return result("unavailable", nil, trainingSamples < configuration.minimumTrainingSamples
                          ? "insufficient_training" : "invalid_training_fit")
        }
        guard let sample, let x = Self.vector(sample, configuration) else { return result("unavailable", nil, "missing_stale_or_conflicting_input") }
        guard fit.accepts(x) else { return result("unavailable", nil, "outside_training_range") }
        var value = fit.predict(x)
        if configuration.correction != .unanchored {
            guard let old = Self.sample(samples, at: a.measuredAt, asOf: min(asOf, a.availableAt), c: configuration),
                  let ax = Self.vector(old, configuration) else { return result("unavailable", nil, "missing_anchor_input") }
            guard fit.accepts(ax) else { return result("unavailable", nil, "anchor_outside_training_range") }
            let gain: Double
            if configuration.correction == .fullResidual { gain = 1 }
            else {
                guard let rho = retentionPerHour else { return result("unavailable", nil, "insufficient_residual_pairs") }
                gain = pow(rho, age / 3600)
            }
            value += gain * (Double(a.value) - fit.predict(ax))
        }
        guard value.isFinite, (0...255).contains(value) else { return result("unavailable", nil, "outside_native_byte_range") }
        return result("estimated", value)
    }

    /// Emits every ten-minute slot including explicit unavailable slots, end-exclusive.
    public func tenMinuteSeries(samples: [RingFatigueSample], anchors: [RingNativeFatigueAnchor],
                                start: Date, end: Date) throws -> [RingFatigueEstimate] {
        guard Self.valid(start), Self.valid(end), end >= start, end.timeIntervalSince(start) <= 366 * 86400 else {
            throw RingError.invalidPacket("invalid fatigue replay window (maximum 366 days)")
        }
        var at = start, results: [RingFatigueEstimate] = []
        while at < end {
            let next = at.addingTimeInterval(600)
            guard Self.valid(next), next > at else {
                throw RingError.invalidPacket("fatigue replay clock cannot advance by ten minutes")
            }
            results.append(try estimate(samples: samples, anchors: anchors, at: at, asOf: at))
            at = next
        }
        return results
    }

    private static func valid(_ date: Date) -> Bool { date.timeIntervalSince1970.isFinite }
    private static func validate(_ samples: [RingFatigueSample], _ anchors: [RingNativeFatigueAnchor]) throws {
        guard samples.allSatisfy({ valid($0.measuredAt) && valid($0.availableAt) && $0.availableAt >= $0.measuredAt && $0.values.values.allSatisfy(\.isFinite) }),
              anchors.allSatisfy({ valid($0.measuredAt) && valid($0.availableAt) && $0.availableAt >= $0.measuredAt }) else {
            throw RingError.invalidPacket("invalid fatigue observation times or values")
        }
    }
    private static func uniqueAnchors(_ anchors: [RingNativeFatigueAnchor]) -> [RingNativeFatigueAnchor] {
        Dictionary(grouping: anchors, by: \.measuredAt).values.compactMap { rows in
            Set(rows.map(\.value)).count == 1 ? rows.min { $0.availableAt < $1.availableAt } : nil
        }
    }
    private static func trainingAnchors(_ anchors: [RingNativeFatigueAnchor], before: Date, asOf: Date,
                                        c: RingFatigueConfiguration) -> [RingNativeFatigueAnchor] {
        uniqueAnchors(anchors.filter {
            $0.measuredAt < before && $0.availableAt <= asOf && before.timeIntervalSince($0.measuredAt) <= c.trainingWindowSeconds
        }).sorted { $0.measuredAt < $1.measuredAt }
    }
    private static func trainingPoints(_ samples: [RingFatigueSample], anchors: [RingNativeFatigueAnchor],
                                       c: RingFatigueConfiguration) -> [Point] {
        anchors.compactMap { anchor in
            guard let input = sample(samples, at: anchor.measuredAt, asOf: anchor.availableAt, c: c),
                  let x = vector(input, c) else { return nil }
            return Point(x: x, y: Double(anchor.value))
        }
    }
    private static func sample(_ samples: [RingFatigueSample], at: Date, asOf: Date, c: RingFatigueConfiguration) -> RingFatigueSample? {
        let visible = samples.filter { $0.measuredAt <= at && $0.availableAt <= asOf && at.timeIntervalSince($0.measuredAt) <= c.maximumSampleAgeSeconds }
        guard let time = visible.map(\.measuredAt).max() else { return nil }
        let rows = visible.filter { $0.measuredAt == time }
        guard let first = rows.first, rows.allSatisfy({ $0.values == first.values }) else { return nil }
        return first
    }
    private static func vector(_ sample: RingFatigueSample, _ c: RingFatigueConfiguration) -> [Double]? {
        let x = c.featureNames.compactMap { sample.values[$0] }
        return x.count == c.featureNames.count ? x : nil
    }
    private static func regress(_ points: [Point], _ penalty: Double) -> Regression? {
        let width = points[0].x.count
        let means = (0..<width).map { j in points.reduce(0) { $0 + $1.x[j] } / Double(points.count) }
        guard means.allSatisfy(\.isFinite) else { return nil }
        let scales = (0..<width).map { j in
            let s = sqrt(points.reduce(0) { $0 + pow($1.x[j] - means[j], 2) } / Double(points.count))
            return s > 0 ? s : 1
        }
        guard scales.allSatisfy(\.isFinite) else { return nil }
        let rows = points.map { p in [1.0] + (0..<width).map { (p.x[$0] - means[$0]) / scales[$0] } }
        guard rows.allSatisfy({ $0.allSatisfy(\.isFinite) }) else { return nil }
        let n = width + 1
        var matrix: [[Double]] = Array(repeating: Array(repeating: 0, count: n + 1), count: n)
        for j in 0..<n {
            for k in 0..<n {
                var sum = 0.0
                for row in rows { sum += row[j] * row[k] }
                matrix[j][k] = sum + (j == k && j > 0 ? penalty : 0)
            }
            for i in points.indices { matrix[j][n] += rows[i][j] * points[i].y }
        }
        for j in 0..<n {
            let pivot = (j..<n).max { abs(matrix[$0][j]) < abs(matrix[$1][j]) }!
            matrix.swapAt(j, pivot)
            let q = matrix[j][j]
            guard q.isFinite, abs(q) > 1e-12 else { return nil }
            matrix[j] = matrix[j].map { $0 / q }
            for i in 0..<n where i != j {
                let factor = matrix[i][j]
                for k in j...n { matrix[i][k] -= factor * matrix[j][k] }
            }
        }
        let coefficients: [Double] = matrix.map { $0[n] }
        guard coefficients.allSatisfy(\.isFinite) else { return nil }
        return Regression(means: means, scales: scales,
            lower: (0..<width).map { j in points.map { $0.x[j] }.min()! },
            upper: (0..<width).map { j in points.map { $0.x[j] }.max()! }, coefficients: coefficients)
    }
}
