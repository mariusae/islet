import Foundation

/// A single CGM reading. Values are always stored in mg/dL.
public struct GlucoseReading: Codable, Hashable, Sendable, Identifiable {
    public var date: Date
    public var value: Int
    public var trend: Trend

    public var id: Date { date }

    public init(date: Date, value: Int, trend: Trend) {
        self.date = date
        self.value = value
        self.trend = trend
    }
}

/// Dexcom trend arrows. Raw values match the Share API's string names.
public enum Trend: String, Codable, Sendable, CaseIterable {
    case none = "None"
    case doubleUp = "DoubleUp"
    case singleUp = "SingleUp"
    case fortyFiveUp = "FortyFiveUp"
    case flat = "Flat"
    case fortyFiveDown = "FortyFiveDown"
    case singleDown = "SingleDown"
    case doubleDown = "DoubleDown"
    case notComputable = "NotComputable"
    case rateOutOfRange = "RateOutOfRange"

    /// Older Share responses encode the trend as an integer index.
    public init(index: Int) {
        let ordered: [Trend] = [.none, .doubleUp, .singleUp, .fortyFiveUp, .flat,
                                .fortyFiveDown, .singleDown, .doubleDown,
                                .notComputable, .rateOutOfRange]
        self = ordered.indices.contains(index) ? ordered[index] : .none
    }

    /// Derive a trend from a rate of change in mg/dL per minute, using Dexcom's buckets.
    public init(rate: Double) {
        switch rate {
        case 3...: self = .doubleUp
        case 2..<3: self = .singleUp
        case 1..<2: self = .fortyFiveUp
        case -1..<1: self = .flat
        case -2 ..< -1: self = .fortyFiveDown
        case -3 ..< -2: self = .singleDown
        default: self = .doubleDown
        }
    }

    /// Rotation of a right-pointing arrow, in degrees (negative is up). `nil` when there is no direction.
    public var angle: Double? {
        switch self {
        case .doubleUp, .singleUp: -90
        case .fortyFiveUp: -45
        case .flat: 0
        case .fortyFiveDown: 45
        case .singleDown, .doubleDown: 90
        case .none, .notComputable, .rateOutOfRange: nil
        }
    }

    public var isDouble: Bool { self == .doubleUp || self == .doubleDown }

    public var arrow: String {
        switch self {
        case .doubleUp: "⇈"
        case .singleUp: "↑"
        case .fortyFiveUp: "↗"
        case .flat: "→"
        case .fortyFiveDown: "↘"
        case .singleDown: "↓"
        case .doubleDown: "⇊"
        case .none, .notComputable, .rateOutOfRange: "–"
        }
    }

    public var label: String {
        switch self {
        case .doubleUp: "Rising quickly"
        case .singleUp: "Rising"
        case .fortyFiveUp: "Rising slowly"
        case .flat: "Steady"
        case .fortyFiveDown: "Falling slowly"
        case .singleDown: "Falling"
        case .doubleDown: "Falling quickly"
        case .none, .notComputable, .rateOutOfRange: "No trend"
        }
    }
}

public enum GlucoseUnit: String, Codable, Sendable, CaseIterable, Identifiable {
    case mgdL
    case mmolL

    public var id: String { rawValue }

    public static let mgPerMmol = 18.0182

    public var label: String {
        switch self {
        case .mgdL: "mg/dL"
        case .mmolL: "mmol/L"
        }
    }

    /// Convert an mg/dL value into this unit.
    public func convert(_ mgdL: Double) -> Double {
        switch self {
        case .mgdL: mgdL
        case .mmolL: mgdL / Self.mgPerMmol
        }
    }

    /// Convert a value in this unit back to mg/dL.
    public func toMgdL(_ value: Double) -> Double {
        switch self {
        case .mgdL: value
        case .mmolL: value * Self.mgPerMmol
        }
    }

    /// Format an mg/dL value for display. Dexcom reports values outside 40–400 as LOW/HIGH.
    public func format(_ mgdL: Int) -> String {
        if mgdL < 40 { return "LOW" }
        if mgdL > 400 { return "HIGH" }
        return formatValue(Double(mgdL))
    }

    public func formatValue(_ mgdL: Double) -> String {
        switch self {
        case .mgdL: String(Int(mgdL.rounded()))
        case .mmolL: String(format: "%.1f", convert(mgdL))
        }
    }

    /// Format a change (in mg/dL) with an explicit sign.
    public func formatDelta(_ mgdL: Double) -> String {
        let v = convert(mgdL)
        let rounded = self == .mgdL ? v.rounded() : (v * 10).rounded() / 10
        if rounded == 0 { return self == .mgdL ? "±0" : "±0.0" }
        let body = self == .mgdL ? String(Int(abs(rounded))) : String(format: "%.1f", abs(rounded))
        return (rounded > 0 ? "+" : "−") + body
    }

    /// Format a rate (mg/dL/min) for display.
    public func formatRate(_ mgdLPerMin: Double) -> String {
        let v = convert(mgdLPerMin)
        let body = self == .mgdL ? String(format: "%.1f", abs(v)) : String(format: "%.2f", abs(v))
        let sign = v > 0.05 ? "+" : (v < -0.05 ? "−" : "")
        return "\(sign)\(body) \(label)/min"
    }
}

/// Where a value sits relative to the configured ranges.
public enum GlucoseLevel: Sendable, Hashable {
    case urgentLow, low, inRange, high, veryHigh

    public static func classify(_ mgdL: Int, low: Int, high: Int, urgentLow: Int = 55, veryHigh: Int = 250) -> GlucoseLevel {
        if mgdL < urgentLow { return .urgentLow }
        if mgdL < low { return .low }
        if mgdL > max(veryHigh, high) { return .veryHigh }
        if mgdL > high { return .high }
        return .inRange
    }
}

public enum GlucoseMath {
    /// Rate of change in mg/dL per minute, from a least-squares fit over readings within `window` of the latest.
    /// Expects readings sorted oldest first.
    public static func rate(_ readings: [GlucoseReading], window: TimeInterval = 15 * 60) -> Double? {
        guard let last = readings.last else { return nil }
        let recent = readings.filter { last.date.timeIntervalSince($0.date) <= window + 30 }
        guard recent.count >= 2 else { return nil }
        let xs = recent.map { $0.date.timeIntervalSince(last.date) / 60 }
        let ys = recent.map { Double($0.value) }
        let n = Double(recent.count)
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (x, y) in zip(xs, ys) {
            num += (x - mx) * (y - my)
            den += (x - mx) * (x - mx)
        }
        guard den > 0 else { return nil }
        return num / den
    }

    /// Change from the previous reading, if it is recent enough to be meaningful.
    public static func delta(_ readings: [GlucoseReading]) -> Int? {
        guard readings.count >= 2 else { return nil }
        let last = readings[readings.count - 1]
        let prev = readings[readings.count - 2]
        guard last.date.timeIntervalSince(prev.date) <= 11 * 60 else { return nil }
        return last.value - prev.value
    }
}

public struct GlucoseStats: Sendable, Equatable {
    public var count: Int
    public var mean: Double
    public var standardDeviation: Double
    public var below: Double
    public var inRange: Double
    public var above: Double

    /// Coefficient of variation, as a fraction.
    public var cv: Double { mean > 0 ? standardDeviation / mean : 0 }
    /// Glucose Management Indicator (estimated A1C), percent.
    public var gmi: Double { 3.31 + 0.02392 * mean }

    public init?(readings: [GlucoseReading], low: Int, high: Int) {
        guard !readings.isEmpty else { return nil }
        let values = readings.map { Double($0.value) }
        let n = Double(values.count)
        count = values.count
        mean = values.reduce(0, +) / n
        let m = mean
        standardDeviation = (values.map { ($0 - m) * ($0 - m) }.reduce(0, +) / n).squareRoot()
        below = Double(readings.filter { $0.value < low }.count) / n
        above = Double(readings.filter { $0.value > high }.count) / n
        inRange = max(0, 1 - below - above)
    }
}
