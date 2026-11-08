import Charts
import IsletKit
import SwiftUI

enum ChartRange: Int, CaseIterable, Identifiable {
    case h3 = 3, h6 = 6, h12 = 12, h24 = 24

    var id: Int { rawValue }
    var label: String { "\(rawValue)H" }
    var interval: TimeInterval { Double(rawValue) * 3600 }

    var axisStrideHours: Int {
        switch self {
        case .h3, .h6: 1
        case .h12: 3
        case .h24: 6
        }
    }

    var showsDots: Bool { self == .h3 || self == .h6 }
}

/// The main glucose chart. Swift Charts provides axes, the target band and scrubbing;
/// the trace itself is drawn as a smooth, range-colored path in an overlay so the
/// color transitions land exactly on the thresholds.
struct GlucoseChart: View {
    let readings: [GlucoseReading]
    let settings: IsletSettings
    let range: ChartRange
    var now: Date = .now

    @State private var selectedDate: Date?

    private var unit: GlucoseUnit { settings.unit }

    private var xDomain: ClosedRange<Date> {
        now.addingTimeInterval(-range.interval)...now.addingTimeInterval(range.interval * 0.035)
    }

    private var visible: [GlucoseReading] {
        let start = xDomain.lowerBound.addingTimeInterval(-10 * 60)
        return readings.filter { $0.date >= start }
    }

    private var yDomainMg: ClosedRange<Double> {
        let maxValue = visible.map(\.value).max() ?? 200
        let minValue = visible.map(\.value).min() ?? 70
        return Double(min(40, minValue - 10))...Double(max(260, maxValue + 30))
    }

    private var yDomain: ClosedRange<Double> {
        unit.convert(yDomainMg.lowerBound)...unit.convert(yDomainMg.upperBound)
    }

    private var gridValues: [Double] {
        switch unit {
        case .mgdL: Array(stride(from: 50.0, through: yDomainMg.upperBound, by: 50))
        case .mmolL: Array(stride(from: 3.0, through: yDomain.upperBound, by: 3))
        }
    }

    private var selected: GlucoseReading? {
        guard let selectedDate else { return nil }
        return visible.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        Chart {
            RectangleMark(
                xStart: .value("Start", xDomain.lowerBound),
                xEnd: .value("End", xDomain.upperBound),
                yStart: .value("Target low", unit.convert(Double(settings.targetLow))),
                yEnd: .value("Target high", unit.convert(Double(settings.targetHigh))))
                .foregroundStyle(
                    LinearGradient(colors: [Palette.inRange.opacity(0.02), Palette.inRange.opacity(0.09)],
                                   startPoint: .leading, endPoint: .trailing))

            RuleMark(y: .value("Target high", unit.convert(Double(settings.targetHigh))))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 5]))
                .foregroundStyle(Palette.high.opacity(0.5))

            RuleMark(y: .value("Target low", unit.convert(Double(settings.targetLow))))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 5]))
                .foregroundStyle(Palette.low.opacity(0.5))
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: range.axisStrideHours)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Theme.grid)
                AxisValueLabel(format: .dateTime.hour(), centered: false)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.axisLabel)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: gridValues) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Theme.grid)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(unit == .mgdL ? "\(Int(v))" : "\(Int(v))")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.axisLabel)
                    }
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartOverlay { proxy in
            GeometryReader { geo in
                if let anchor = proxy.plotFrame {
                    let frame = geo[anchor]
                    GlucoseTrace(
                        points: tracePoints(proxy: proxy),
                        stops: Palette.rangeStops(
                            minV: yDomainMg.lowerBound, maxV: yDomainMg.upperBound,
                            urgentLow: Double(settings.alerts.urgentLow),
                            low: Double(settings.targetLow), high: Double(settings.targetHigh)),
                        showsDots: range.showsDots,
                        latestColor: latestColor,
                        selection: selectionPoint(proxy: proxy))
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .allowsHitTesting(false)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selected?.date)
    }

    private var latestColor: Color {
        guard let latest = readings.last else { return .secondary }
        return Palette.color(for: settings.level(latest.value))
    }

    private func tracePoints(proxy: ChartProxy) -> [GlucoseTrace.Point] {
        visible.compactMap { r in
            guard let x = proxy.position(forX: r.date),
                  let y = proxy.position(forY: unit.convert(Double(r.value))) else { return nil }
            return .init(date: r.date, location: CGPoint(x: x, y: y),
                         color: Palette.color(for: settings.level(r.value)))
        }
    }

    private func selectionPoint(proxy: ChartProxy) -> GlucoseTrace.Selection? {
        guard let selected,
              let x = proxy.position(forX: selected.date),
              let y = proxy.position(forY: unit.convert(Double(selected.value))) else { return nil }
        return .init(
            location: CGPoint(x: x, y: y),
            color: Palette.color(for: settings.level(selected.value)),
            value: unit.format(selected.value),
            unit: unit.label,
            time: selected.date.formatted(date: .omitted, time: .shortened))
    }
}

/// Draws the smoothed glucose line, its soft area fill, reading dots, the live "now" point, and the scrub callout.
struct GlucoseTrace: View {
    struct Point {
        var date: Date
        var location: CGPoint
        var color: Color
    }

    struct Selection {
        var location: CGPoint
        var color: Color
        var value: String
        var unit: String
        var time: String
    }

    let points: [Point]
    let stops: [Gradient.Stop]
    let showsDots: Bool
    let latestColor: Color
    let selection: Selection?

    @State private var pulse = false
    @Environment(\.colorScheme) private var colorScheme

    private var gradient: LinearGradient {
        LinearGradient(stops: stops, startPoint: .bottom, endPoint: .top)
    }

    var body: some View {
        GeometryReader { geo in
            let segments = Self.segments(points)
            ZStack(alignment: .topLeading) {
                // Area fill under the curve, fading toward the bottom.
                ForEach(segments.indices, id: \.self) { i in
                    Self.areaPath(segments[i].map(\.location), bottom: geo.size.height)
                        .fill(gradient.opacity(0.22))
                }
                .mask(LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .top, endPoint: .bottom))

                // Glow + crisp line.
                ForEach(segments.indices, id: \.self) { i in
                    let path = Self.smoothPath(segments[i].map(\.location))
                    path.stroke(gradient, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                        .blur(radius: 6)
                        .opacity(colorScheme == .dark ? 0.55 : 0.3)
                    path.stroke(gradient, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }

                if showsDots {
                    ForEach(points.indices.dropLast(), id: \.self) { i in
                        Circle()
                            .fill(points[i].color)
                            .frame(width: 4, height: 4)
                            .position(points[i].location)
                    }
                }

                if let last = points.last {
                    Circle()
                        .fill(latestColor.opacity(0.25))
                        .frame(width: 26, height: 26)
                        .scaleEffect(pulse ? 1.25 : 0.7)
                        .opacity(pulse ? 0 : 1)
                        .position(last.location)
                    Circle()
                        .fill(latestColor)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(Theme.background.opacity(0.7), lineWidth: 2))
                        .shadow(color: latestColor.opacity(0.8), radius: 6)
                        .position(last.location)
                }

                if let selection {
                    Rectangle()
                        .fill(LinearGradient(colors: [Color.primary.opacity(0.0), Color.primary.opacity(0.3)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 1, height: geo.size.height)
                        .position(x: selection.location.x, y: geo.size.height / 2)
                    Circle()
                        .fill(selection.color)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().strokeBorder(Theme.field, lineWidth: 2))
                        .position(selection.location)
                    callout(selection)
                        .fixedSize()
                        .position(x: min(max(selection.location.x, 44), geo.size.width - 44), y: 4)
                }
            }
        }
        .clipped()
        .onAppear {
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true }
        }
    }

    private func callout(_ s: Selection) -> some View {
        VStack(spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(s.value)
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(s.color)
                Text(s.unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(s.time)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.cardStroke))
        .offset(y: 22)
    }

    /// Split into contiguous runs; a gap of more than 12 minutes breaks the line.
    static func segments(_ points: [Point]) -> [[Point]] {
        var result: [[Point]] = []
        var current: [Point] = []
        for p in points {
            if let last = current.last, p.date.timeIntervalSince(last.date) > 12 * 60 {
                result.append(current)
                current = []
            }
            current.append(p)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Monotone cubic (Fritsch–Carlson) interpolation: smooth, but never overshoots the data.
    static func smoothPath(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count > 1 else {
            path.addLine(to: first)
            return path
        }
        let n = pts.count
        var d = [CGFloat](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = pts[i + 1].x - pts[i].x
            d[i] = dx == 0 ? 0 : (pts[i + 1].y - pts[i].y) / dx
        }
        var m = [CGFloat](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        if n > 2 {
            for i in 1..<(n - 1) {
                m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2
            }
        }
        for i in 0..<(n - 1) {
            if d[i] == 0 {
                m[i] = 0
                m[i + 1] = 0
                continue
            }
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[i] = t * a * d[i]
                m[i + 1] = t * b * d[i]
            }
        }
        for i in 0..<(n - 1) {
            let dx = (pts[i + 1].x - pts[i].x) / 3
            path.addCurve(
                to: pts[i + 1],
                control1: CGPoint(x: pts[i].x + dx, y: pts[i].y + m[i] * dx),
                control2: CGPoint(x: pts[i + 1].x - dx, y: pts[i + 1].y - m[i + 1] * dx))
        }
        return path
    }

    static func areaPath(_ pts: [CGPoint], bottom: CGFloat) -> Path {
        guard let first = pts.first, let last = pts.last else { return Path() }
        var path = smoothPath(pts)
        path.addLine(to: CGPoint(x: last.x, y: bottom))
        path.addLine(to: CGPoint(x: first.x, y: bottom))
        path.closeSubpath()
        return path
    }
}
