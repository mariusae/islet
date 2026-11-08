import IsletKit
import SwiftUI

struct DashboardView: View {
    @Environment(GlucoseStore.self) private var store
    @AppStorage("chartRange") private var range: ChartRange = .h6
    @State private var showSettings = false

    private var levelColor: Color {
        guard let latest = store.latest, Date.now.timeIntervalSince(latest.date) <= AlertEngine.staleAfter else {
            return Theme.stale
        }
        return Palette.color(for: store.settings.level(latest.value))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if store.mode == .demo {
                        Text("DEMO DATA")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .tracking(0.8)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Palette.accent.opacity(0.18), in: Capsule())
                            .foregroundStyle(Palette.accent)
                    }

                    HeroView(readings: store.readings, settings: store.settings, alerts: store.alerts)
                        .padding(.top, 8)
                        .padding(.bottom, 12)

                    if let error = store.lastError {
                        ErrorBanner(message: error)
                    }

                    chartCard
                    StatsCard(readings: store.readings, settings: store.settings, range: range)
                    LiveActivityCard()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(Backdrop(color: levelColor))
            .refreshable { await store.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("History")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                RangePicker(selection: $range)
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                GlucoseChart(readings: store.readings, settings: store.settings, range: range, now: context.date)
                    .frame(height: 260)
            }
        }
        .card()
    }
}

// MARK: - Hero

struct HeroView: View {
    let readings: [GlucoseReading]
    let settings: IsletSettings
    let alerts: [AlertKind]

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            if let latest = readings.last {
                content(latest: latest, now: context.date)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Waiting for readings…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 200)
            }
        }
    }

    @ViewBuilder
    private func content(latest: GlucoseReading, now: Date) -> some View {
        let stale = now.timeIntervalSince(latest.date) > AlertEngine.staleAfter
        let color = stale ? Theme.stale : Palette.color(for: settings.level(latest.value))
        let unit = settings.unit

        VStack(spacing: 4) {
            HStack(spacing: 6) {
                if stale {
                    Label("NO RECENT DATA", systemImage: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.fill, in: Capsule())
                } else {
                    ForEach(alerts, id: \.self) { AlertBadge(alert: $0) }
                }
            }
            .frame(height: 24)

            HStack(alignment: .center, spacing: 4) {
                Text(unit.format(latest.value))
                    .font(.system(size: 108, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(latest.value)))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                TrendArrowView(trend: latest.trend, size: 46, weight: .semibold)
                    .opacity(stale ? 0.3 : 1)
            }
            .foregroundStyle(color)
            .shadow(color: color.opacity(colorScheme == .dark ? 0.35 : 0.18), radius: 24)

            HStack(spacing: 8) {
                Text(unit.label)
                if let delta = GlucoseMath.delta(readings) {
                    Text("·").foregroundStyle(.tertiary)
                    Text(unit.formatDelta(Double(delta)))
                        .monospacedDigit()
                }
                Text("·").foregroundStyle(.tertiary)
                Text(Self.age(of: latest.date, now: now))
            }
            .font(.system(.subheadline, design: .rounded).weight(.medium))
            .foregroundStyle(.secondary)

            if !stale, let rate = GlucoseMath.rate(readings) {
                Text("\(latest.trend.label) · \(unit.formatRate(rate))")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: latest.value)
        .accessibilityElement(children: .combine)
    }

    static func age(of date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        switch minutes {
        case ..<1: return "Just now"
        case ..<60: return "\(minutes) min ago"
        default: return date.formatted(date: .omitted, time: .shortened)
        }
    }
}

// MARK: - Range picker

struct RangePicker: View {
    @Binding var selection: ChartRange
    @Namespace private var namespace
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ChartRange.allCases) { range in
                Button {
                    withAnimation(.snappy(duration: 0.3)) { selection = range }
                } label: {
                    Text(range.label)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(selection == range ? .primary : .secondary)
                        .frame(width: 38, height: 26)
                        .background {
                            if selection == range {
                                Capsule()
                                    .fill(Theme.selection)
                                    .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.08), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.fill, in: Capsule())
        .sensoryFeedback(.selection, trigger: selection)
    }
}

// MARK: - Stats

struct StatsCard: View {
    let readings: [GlucoseReading]
    let settings: IsletSettings
    let range: ChartRange

    var body: some View {
        let cutoff = Date.now.addingTimeInterval(-range.interval)
        let window = readings.filter { $0.date >= cutoff }
        let stats = GlucoseStats(readings: window, low: settings.targetLow, high: settings.targetHigh)

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Time in range")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Last \(range.rawValue) hours")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let stats {
                RangeBar(below: stats.below, inRange: stats.inRange, above: stats.above)

                HStack(spacing: 0) {
                    legend("Low", stats.below, Palette.low)
                    legend("In range", stats.inRange, Palette.inRange)
                    legend("High", stats.above, Palette.high)
                }

                Divider().overlay(Theme.hairline)

                HStack(spacing: 0) {
                    metric("Average", settings.unit.formatValue(stats.mean), settings.unit.label)
                    metric("GMI", String(format: "%.1f", stats.gmi), "%")
                    metric("Variability", String(format: "%.0f", stats.cv * 100), "% CV")
                }
            } else {
                Text("No readings yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private func legend(_ title: String, _ fraction: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(fraction, format: .percent.precision(.fractionLength(0)))
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Text(unit).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RangeBar: View {
    let below: Double
    let inRange: Double
    let above: Double

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 3
            let parts = [(below, Palette.low), (inRange, Palette.inRange), (above, Palette.high)].filter { $0.0 > 0.004 }
            let available = geo.size.width - spacing * CGFloat(max(parts.count - 1, 0))
            HStack(spacing: spacing) {
                ForEach(parts.indices, id: \.self) { i in
                    Capsule()
                        .fill(parts[i].1.gradient)
                        .frame(width: max(available * parts[i].0, 6))
                }
            }
        }
        .frame(height: 10)
    }
}

// MARK: - Shared chrome

struct Backdrop: View {
    let color: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let strength = colorScheme == .dark ? 1.0 : 0.75
        ZStack {
            Theme.background
            RadialGradient(colors: [color.opacity(0.22 * strength), color.opacity(0.05 * strength), .clear],
                           center: .init(x: 0.5, y: 0.0), startRadius: 10, endRadius: 520)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 1.2), value: color)
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.medium))
            .foregroundStyle(Palette.low)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Palette.low.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

extension View {
    func card() -> some View {
        padding(16)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1))
    }
}

#Preview {
    DashboardView()
        .environment(GlucoseStore.shared)
}
