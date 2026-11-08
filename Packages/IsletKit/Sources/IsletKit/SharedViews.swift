import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Color {
    /// A color that resolves to `light` or `dark` with the environment's color scheme.
    public static func adaptive(light: Color, dark: Color) -> Color {
        #if canImport(UIKit) && !os(watchOS)
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
        #elseif canImport(AppKit)
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light) })
        #else
        dark
        #endif
    }
}

/// Range colors. Dark appearance uses bright, glowing tones; light appearance deepens them so they
/// keep their contrast on white.
public enum Palette {
    public static let urgentLow = Color.adaptive(light: Color(red: 0.85, green: 0.09, blue: 0.24),
                                                 dark: Color(red: 1.00, green: 0.23, blue: 0.36))
    public static let low = Color.adaptive(light: Color(red: 0.90, green: 0.25, blue: 0.27),
                                           dark: Color(red: 1.00, green: 0.42, blue: 0.42))
    public static let inRange = Color.adaptive(light: Color(red: 0.04, green: 0.62, blue: 0.45),
                                               dark: Color(red: 0.18, green: 0.83, blue: 0.63))
    public static let high = Color.adaptive(light: Color(red: 0.87, green: 0.51, blue: 0.00),
                                            dark: Color(red: 1.00, green: 0.70, blue: 0.14))
    public static let veryHigh = Color.adaptive(light: Color(red: 0.88, green: 0.36, blue: 0.06),
                                                dark: Color(red: 1.00, green: 0.54, blue: 0.24))
    public static let accent = Color.adaptive(light: Color(red: 0.00, green: 0.48, blue: 0.80),
                                              dark: Color(red: 0.36, green: 0.78, blue: 0.98))

    public static func color(for level: GlucoseLevel) -> Color {
        switch level {
        case .urgentLow: urgentLow
        case .low: low
        case .inRange: inRange
        case .high: high
        case .veryHigh: veryHigh
        }
    }

    public static func color(for alert: AlertKind) -> Color {
        switch alert {
        case .urgentLow: urgentLow
        case .low, .fallingFast: low
        case .high, .risingFast: high
        }
    }

    /// Gradient stops that map vertical position to range colors.
    /// `minV`/`maxV` are the values at the bottom (location 0) and top (location 1).
    public static func rangeStops(minV: Double, maxV: Double, urgentLow uLow: Double, low lowV: Double, high highV: Double,
                                  veryHigh vHigh: Double = 250, opacity: Double = 1) -> [Gradient.Stop] {
        let span = max(maxV - minV, 1)
        func loc(_ v: Double) -> CGFloat { CGFloat(min(max((v - minV) / span, 0), 1)) }
        let feather = 4 / span  // soften transitions slightly
        var stops: [Gradient.Stop] = [
            .init(color: urgentLow.opacity(opacity), location: 0),
            .init(color: urgentLow.opacity(opacity), location: loc(uLow)),
            .init(color: low.opacity(opacity), location: min(loc(uLow) + feather, loc(lowV))),
            .init(color: low.opacity(opacity), location: loc(lowV)),
            .init(color: inRange.opacity(opacity), location: min(loc(lowV) + feather, 1)),
            .init(color: inRange.opacity(opacity), location: loc(highV)),
            .init(color: high.opacity(opacity), location: min(loc(highV) + feather, 1)),
        ]
        if vHigh > highV {
            stops.append(.init(color: high.opacity(opacity), location: loc(vHigh)))
            stops.append(.init(color: veryHigh.opacity(opacity), location: min(loc(vHigh) + feather, 1)))
            stops.append(.init(color: veryHigh.opacity(opacity), location: 1))
        } else {
            stops.append(.init(color: high.opacity(opacity), location: 1))
        }
        return stops.sorted { $0.location < $1.location }
    }
}

/// A trend arrow drawn from SF Symbols, rotated to match the Dexcom trend.
public struct TrendArrowView: View {
    public let trend: Trend
    public let size: CGFloat
    public var weight: Font.Weight

    public init(trend: Trend, size: CGFloat, weight: Font.Weight = .bold) {
        self.trend = trend
        self.size = size
        self.weight = weight
    }

    public var body: some View {
        Group {
            if let angle = trend.angle {
                ZStack {
                    if trend.isDouble {
                        arrow.offset(x: -size * 0.22)
                        arrow.offset(x: size * 0.22)
                    } else {
                        arrow
                    }
                }
                .rotationEffect(.degrees(angle))
            } else {
                Image(systemName: "minus")
                    .font(.system(size: size * 0.8, weight: weight))
            }
        }
        .frame(width: size * 1.25, height: size * 1.25)
        .accessibilityLabel(trend.label)
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: size, weight: weight))
    }
}

/// A compact two-hour trace for the Live Activity, drawn with paths for predictable rendering.
public struct SparklineView: View {
    public let points: [SparkPoint]
    public let low: Int
    public let high: Int
    public let urgentLow: Int
    public var span: Int
    public var lineWidth: CGFloat
    public var showsBand: Bool

    public init(points: [SparkPoint], low: Int, high: Int, urgentLow: Int = 55,
                span: Int = GlucoseActivityState.historyMinutes, lineWidth: CGFloat = 2.5, showsBand: Bool = true) {
        self.points = points.sorted { $0.m > $1.m }
        self.low = low
        self.high = high
        self.urgentLow = urgentLow
        self.span = span
        self.lineWidth = lineWidth
        self.showsBand = showsBand
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let values = points.map(\.v)
            // Fit the data (with a minimum span) so small trends stay readable; the band is clipped to fit.
            let lo = Double(values.min() ?? low), hi = Double(values.max() ?? high)
            let valueSpan = max(hi - lo, 70) * 1.15
            let minV = (lo + hi) / 2 - valueSpan / 2
            let maxV = (lo + hi) / 2 + valueSpan / 2
            let inset = lineWidth * 2.5
            let pt: (SparkPoint) -> CGPoint = { p in
                CGPoint(x: inset + (w - inset * 2) * (1 - CGFloat(p.m) / CGFloat(span)),
                        y: inset + (h - inset * 2) * CGFloat(1 - (Double(p.v) - minV) / (maxV - minV)))
            }
            let yOf: (Int) -> CGFloat = { v in
                inset + (h - inset * 2) * CGFloat(1 - (Double(v) - minV) / (maxV - minV))
            }

            ZStack(alignment: .topLeading) {
                if showsBand {
                    let top = max(yOf(high), 0), bottom = min(yOf(low), h)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Palette.inRange.opacity(0.14))
                        .frame(width: w, height: max(bottom - top, 1))
                        .offset(y: top)
                }

                Path { path in
                    for (i, p) in points.enumerated() {
                        i == 0 ? path.move(to: pt(p)) : path.addLine(to: pt(p))
                    }
                }
                .stroke(
                    LinearGradient(
                        stops: Palette.rangeStops(
                            minV: minV + (maxV - minV) * Double(inset / h),
                            maxV: maxV - (maxV - minV) * Double(inset / h),
                            urgentLow: Double(urgentLow), low: Double(low), high: Double(high)),
                        startPoint: .bottom, endPoint: .top),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

                if let last = points.last {
                    let p = pt(last)
                    let color = Palette.color(for: GlucoseLevel.classify(last.v, low: low, high: high, urgentLow: urgentLow))
                    Circle()
                        .fill(color.opacity(0.3))
                        .frame(width: lineWidth * 5, height: lineWidth * 5)
                        .position(p)
                    Circle()
                        .fill(color)
                        .frame(width: lineWidth * 2.6, height: lineWidth * 2.6)
                        .position(p)
                }
            }
        }
    }
}

/// Small capsule naming the active alert.
public struct AlertBadge: View {
    public let alert: AlertKind
    public var compact: Bool

    public init(alert: AlertKind, compact: Bool = false) {
        self.alert = alert
        self.compact = compact
    }

    public var body: some View {
        Label(alert.title.uppercased(), systemImage: alert.symbol)
            .font(.system(size: compact ? 10 : 11, weight: .bold, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(Palette.color(for: alert))
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 2 : 3)
            .background(Palette.color(for: alert).opacity(0.18), in: Capsule())
    }
}
