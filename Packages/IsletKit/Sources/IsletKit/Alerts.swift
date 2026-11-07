import Foundation

/// Conditions that make Islet raise a Live Activity. Declaration order is priority order.
public enum AlertKind: String, Codable, Sendable, CaseIterable, Comparable {
    case urgentLow
    case low
    case fallingFast
    case high
    case risingFast

    public static func < (a: AlertKind, b: AlertKind) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    public var title: String {
        switch self {
        case .urgentLow: "Urgent Low"
        case .low: "Low"
        case .fallingFast: "Falling Fast"
        case .high: "High"
        case .risingFast: "Rising Fast"
        }
    }

    public var symbol: String {
        switch self {
        case .urgentLow: "exclamationmark.triangle.fill"
        case .low: "arrow.down.to.line"
        case .fallingFast: "chevron.down.2"
        case .high: "arrow.up.to.line"
        case .risingFast: "chevron.up.2"
        }
    }
}

public struct AlertSettings: Codable, Equatable, Sendable {
    public var urgentLowEnabled = true
    public var urgentLow = 55
    public var lowEnabled = true
    public var low = 70
    public var highEnabled = true
    public var high = 220
    public var risingEnabled = true
    /// mg/dL per minute.
    public var riseRate = 2.0
    public var fallingEnabled = true
    /// mg/dL per minute (positive number).
    public var fallRate = 2.0
    /// Keep the Live Activity up this long after every condition has cleared.
    public var clearAfterMinutes = 20
    /// Keep a Live Activity running at all times, not only during alerts.
    public var alwaysOn = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AlertSettings()
        urgentLowEnabled = try c.decodeIfPresent(Bool.self, forKey: .urgentLowEnabled) ?? d.urgentLowEnabled
        urgentLow = try c.decodeIfPresent(Int.self, forKey: .urgentLow) ?? d.urgentLow
        lowEnabled = try c.decodeIfPresent(Bool.self, forKey: .lowEnabled) ?? d.lowEnabled
        low = try c.decodeIfPresent(Int.self, forKey: .low) ?? d.low
        highEnabled = try c.decodeIfPresent(Bool.self, forKey: .highEnabled) ?? d.highEnabled
        high = try c.decodeIfPresent(Int.self, forKey: .high) ?? d.high
        risingEnabled = try c.decodeIfPresent(Bool.self, forKey: .risingEnabled) ?? d.risingEnabled
        riseRate = try c.decodeIfPresent(Double.self, forKey: .riseRate) ?? d.riseRate
        fallingEnabled = try c.decodeIfPresent(Bool.self, forKey: .fallingEnabled) ?? d.fallingEnabled
        fallRate = try c.decodeIfPresent(Double.self, forKey: .fallRate) ?? d.fallRate
        clearAfterMinutes = try c.decodeIfPresent(Int.self, forKey: .clearAfterMinutes) ?? d.clearAfterMinutes
        alwaysOn = try c.decodeIfPresent(Bool.self, forKey: .alwaysOn) ?? d.alwaysOn
    }
}

public struct IsletSettings: Codable, Equatable, Sendable {
    public var unit: GlucoseUnit = .mgdL
    /// Target range, used for the chart band, colors, and time-in-range.
    public var targetLow = 70
    public var targetHigh = 180
    public var alerts = AlertSettings()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = IsletSettings()
        unit = try c.decodeIfPresent(GlucoseUnit.self, forKey: .unit) ?? d.unit
        targetLow = try c.decodeIfPresent(Int.self, forKey: .targetLow) ?? d.targetLow
        targetHigh = try c.decodeIfPresent(Int.self, forKey: .targetHigh) ?? d.targetHigh
        alerts = try c.decodeIfPresent(AlertSettings.self, forKey: .alerts) ?? d.alerts
    }

    public func level(_ mgdL: Int) -> GlucoseLevel {
        GlucoseLevel.classify(mgdL, low: targetLow, high: targetHigh, urgentLow: alerts.urgentLow)
    }
}

public enum AlertEngine {
    /// Readings older than this are treated as no data; nothing alerts on stale values.
    public static let staleAfter: TimeInterval = 15 * 60
    /// A glucose alert clears only once the value is this far back inside its threshold (mg/dL).
    public static let clearMargin = 5
    /// Likewise for rate alerts (mg/dL per minute), capped at a quarter of the threshold.
    public static let rateClearMargin = 0.5

    public static func isStale(_ readings: [GlucoseReading], now: Date = .now) -> Bool {
        guard let latest = readings.last else { return true }
        return now.timeIntervalSince(latest.date) > staleAfter
    }

    /// Active alert conditions for the latest reading, highest priority first.
    ///
    /// `previous` is the result of the last evaluation. An alert that was already active stays active
    /// until the value is a margin back inside its threshold, so readings hovering around a threshold
    /// don't flip the alert on and off. Stale data yields no alerts; callers handle signal loss.
    public static func evaluate(_ readings: [GlucoseReading], settings: AlertSettings, now: Date = .now,
                                previous: [AlertKind] = []) -> [AlertKind] {
        guard let latest = readings.last, !isStale(readings, now: now) else { return [] }
        let was = Set(previous)
        var result: [AlertKind] = []
        let v = latest.value
        if settings.urgentLowEnabled,
           v < settings.urgentLow || (was.contains(.urgentLow) && v < settings.urgentLow + clearMargin) {
            result.append(.urgentLow)
        } else if settings.lowEnabled,
                  v < settings.low || (!was.isDisjoint(with: [.low, .urgentLow]) && v < settings.low + clearMargin) {
            result.append(.low)
        }
        if settings.highEnabled, v > settings.high || (was.contains(.high) && v > settings.high - clearMargin) {
            result.append(.high)
        }
        if let rate = GlucoseMath.rate(readings) {
            let rise = settings.riseRate - min(rateClearMargin, settings.riseRate / 4)
            let fall = settings.fallRate - min(rateClearMargin, settings.fallRate / 4)
            if settings.risingEnabled, rate >= settings.riseRate || (was.contains(.risingFast) && rate >= rise) {
                result.append(.risingFast)
            }
            if settings.fallingEnabled, rate <= -settings.fallRate || (was.contains(.fallingFast) && rate <= -fall) {
                result.append(.fallingFast)
            }
        }
        return result.sorted()
    }

    /// Which of `alerts` deserve a sound: those not active at any point in the last `clearAfter`.
    /// An alert announces once per episode, however often its condition flickers. `history` (when each
    /// kind was last active) is updated in place. Urgent low also marks low as seen, so recovering
    /// from urgent low through low stays quiet.
    public static func announce(_ alerts: [AlertKind], history: inout [AlertKind: Date], now: Date = .now,
                                clearAfter: TimeInterval) -> [AlertKind] {
        let fresh = alerts.filter { kind in
            guard let seen = history[kind] else { return true }
            return now.timeIntervalSince(seen) >= clearAfter
        }
        for kind in alerts { history[kind] = now }
        if alerts.contains(.urgentLow) { history[.low] = now }
        return fresh
    }
}

/// Decides what to do with the Live Activity after each new reading.
public enum ActivityPolicy {
    public enum Decision: Equatable, Sendable {
        case start, update, end, none
    }

    /// - Parameters:
    ///   - alerts: current alert conditions.
    ///   - isRunning: whether an Islet Live Activity is currently running.
    ///   - keepAlive: always-on mode, or the user pinned the activity manually.
    ///   - lastAlertDate: when any alert condition was last observed.
    ///   - stale: no reading for 15 minutes. A running activity is held: silence isn't evidence of
    ///     recovery, and the activity shows itself as stale.
    public static func decide(
        alerts: [AlertKind],
        isRunning: Bool,
        keepAlive: Bool,
        lastAlertDate: Date?,
        clearAfter: TimeInterval,
        now: Date = .now,
        stale: Bool = false
    ) -> Decision {
        if !alerts.isEmpty || keepAlive {
            return isRunning ? .update : .start
        }
        guard isRunning else { return .none }
        if stale { return .update }
        if let last = lastAlertDate, now.timeIntervalSince(last) < clearAfter {
            return .update
        }
        return .end
    }
}

/// A recent value for the Live Activity sparkline: `m` minutes before the latest reading.
public struct SparkPoint: Codable, Hashable, Sendable {
    public var m: Int
    public var v: Int

    public init(m: Int, v: Int) {
        self.m = m
        self.v = v
    }
}

/// Everything the Live Activity renders. Kept small: ActivityKit payloads are capped at 4 KB.
///
/// The Islet server sends this same structure as APNs `content-state` JSON, so the encoding is
/// deliberately plain: enums are their raw strings and the reading time is Unix seconds.
public struct GlucoseActivityState: Codable, Hashable, Sendable {
    public var value: Int
    public var trend: Trend
    /// Reading time, Unix seconds.
    public var timestamp: Int
    public var delta: Int?
    public var alerts: [AlertKind]
    public var unit: GlucoseUnit
    public var targetLow: Int
    public var targetHigh: Int
    public var urgentLow: Int
    public var history: [SparkPoint]

    public static let historyMinutes = 120

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }

    public init(value: Int, trend: Trend, date: Date, delta: Int?, alerts: [AlertKind], unit: GlucoseUnit,
                targetLow: Int, targetHigh: Int, urgentLow: Int, history: [SparkPoint]) {
        self.value = value
        self.trend = trend
        self.timestamp = Int(date.timeIntervalSince1970)
        self.delta = delta
        self.alerts = alerts
        self.unit = unit
        self.targetLow = targetLow
        self.targetHigh = targetHigh
        self.urgentLow = urgentLow
        self.history = history
    }

    public init?(readings: [GlucoseReading], settings: IsletSettings, alerts: [AlertKind]) {
        guard let latest = readings.last else { return nil }
        let history = readings
            .map { SparkPoint(m: Int(latest.date.timeIntervalSince($0.date) / 60), v: $0.value) }
            .filter { $0.m <= Self.historyMinutes }
        self.init(value: latest.value, trend: latest.trend, date: latest.date,
                  delta: GlucoseMath.delta(readings), alerts: alerts, unit: settings.unit,
                  targetLow: settings.targetLow, targetHigh: settings.targetHigh,
                  urgentLow: settings.alerts.urgentLow, history: history)
    }

    public var level: GlucoseLevel {
        GlucoseLevel.classify(value, low: targetLow, high: targetHigh, urgentLow: urgentLow)
    }

    public var formattedValue: String { unit.format(value) }
    public var formattedDelta: String? { delta.map { unit.formatDelta(Double($0)) } }
}
