import Foundation

/// Deterministic, realistic-looking synthetic CGM data, for demo mode and previews.
/// Values are a pure function of time, so successive refreshes line up seamlessly.
public enum DemoData {
    public static let interval: TimeInterval = 5 * 60

    public static func readings(endingAt now: Date = .now, hours: Int = 24) -> [GlucoseReading] {
        let end = (now.timeIntervalSince1970 / interval).rounded(.down) * interval
        let count = hours * 12
        let times = (0..<count).reversed().map { end - Double($0) * interval }
        let values = times.map(value(at:))
        return times.indices.map { i in
            let rate = i >= 3 ? (values[i] - values[i - 3]) / 15 : 0
            return GlucoseReading(date: Date(timeIntervalSince1970: times[i]),
                                  value: Int(values[i].rounded()),
                                  trend: Trend(rate: rate))
        }
    }

    static func value(at t: TimeInterval) -> Double {
        let hour = 3600.0
        var v = 128.0
        v += 42 * sin(2 * .pi * t / (7.7 * hour))
        v += 22 * sin(2 * .pi * t / (2.3 * hour) + 1.1)
        // Meal-like excursions: sharp rise, slow decay.
        let mealPeriod = 5.3 * hour
        let phase = t.truncatingRemainder(dividingBy: mealPeriod) / hour
        v += 95 * (phase / 0.9) * exp(1 - phase / 0.9) * (phase < 4 ? 1 : 0)
        // Occasional dips.
        let dip = sin(2 * .pi * t / (11.1 * hour) + 0.4)
        if dip > 0.8 { v -= 160 * (dip - 0.8) / 0.2 * 0.55 }
        // Small deterministic sensor noise.
        let n = sin(t * 12.9898) * 43758.5453
        v += (n - n.rounded(.down) - 0.5) * 2.5
        return min(max(v, 42), 380)
    }
}
