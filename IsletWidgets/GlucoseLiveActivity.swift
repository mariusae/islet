import ActivityKit
import IsletKit
import SwiftUI
import WidgetKit

@main
struct IsletWidgetsBundle: WidgetBundle {
    var body: some Widget {
        GlucoseLiveActivity()
    }
}

struct GlucoseLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GlucoseActivityAttributes.self) { context in
            LiveActivityView(state: context.state, isStale: context.isStale)
                // The Lock Screen card keeps its dark tint in either appearance, so use the dark palette.
                .environment(\.colorScheme, .dark)
                .activityBackgroundTint(Color(red: 0.04, green: 0.045, blue: 0.06).opacity(0.92))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            let color = context.isStale ? Color.gray : Palette.color(for: state.level)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .center, spacing: 2) {
                            Text(state.formattedValue)
                                .font(.system(size: 40, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .minimumScaleFactor(0.7)
                                .lineLimit(1)
                            TrendArrowView(trend: state.trend, size: 20)
                        }
                        .foregroundStyle(color)
                        Text(state.unit.label)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        if let delta = state.formattedDelta {
                            Text(delta)
                                .font(.system(.title3, design: .rounded).weight(.semibold))
                                .monospacedDigit()
                        }
                        Text(state.date, style: .time)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 4)
                    .padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    if let alert = state.alerts.first {
                        AlertBadge(alert: alert, compact: true)
                    } else if context.isStale {
                        Text("NO RECENT DATA")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    SparklineView(points: state.history, low: state.targetLow, high: state.targetHigh,
                                  urgentLow: state.urgentLow, lineWidth: 2.5)
                        .frame(height: 44)
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                }
            } compactLeading: {
                Text(state.formattedValue)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
            } compactTrailing: {
                TrendArrowView(trend: state.trend, size: 13)
                    .foregroundStyle(color)
            } minimal: {
                Text(state.formattedValue)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(color)
            }
            .keylineTint(color)
        }
        .supplementalActivityFamilies([.small])
    }
}

/// Lock Screen / banner (medium) and Apple Watch Smart Stack / CarPlay (small) presentation.
struct LiveActivityView: View {
    let state: GlucoseActivityState
    let isStale: Bool

    @Environment(\.activityFamily) private var family

    private var color: Color { isStale ? .gray : Palette.color(for: state.level) }

    var body: some View {
        switch family {
        case .small:
            small
        default:
            medium
        }
    }

    private var medium: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                header
                HStack(alignment: .center, spacing: 4) {
                    Text(state.formattedValue)
                        .font(.system(size: 50, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    TrendArrowView(trend: state.trend, size: 24)
                }
                .foregroundStyle(color)
                .opacity(isStale ? 0.6 : 1)
                footer
            }
            .fixedSize(horizontal: true, vertical: false)

            SparklineView(points: state.history, low: state.targetLow, high: state.targetHigh,
                          urgentLow: state.urgentLow, lineWidth: 2.5)
                .frame(maxWidth: .infinity)
                .frame(height: 76)
                .opacity(isStale ? 0.5 : 1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var small: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                if let alert = state.alerts.first {
                    Text(alert.title.uppercased())
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.color(for: alert))
                        .lineLimit(1)
                } else {
                    Text(isStale ? "NO DATA" : "GLUCOSE")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .center, spacing: 2) {
                    Text(state.formattedValue)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    TrendArrowView(trend: state.trend, size: 15)
                }
                .foregroundStyle(color)
                HStack(spacing: 4) {
                    if let delta = state.formattedDelta { Text(delta).monospacedDigit() }
                    Text(state.date, style: .time)
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)

            SparklineView(points: state.history, low: state.targetLow, high: state.targetHigh,
                          urgentLow: state.urgentLow, lineWidth: 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(8)
    }

    @ViewBuilder
    private var header: some View {
        if isStale {
            Label("NO RECENT DATA", systemImage: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
        } else if !state.alerts.isEmpty {
            HStack(spacing: 4) {
                ForEach(state.alerts.prefix(2), id: \.self) { AlertBadge(alert: $0, compact: true) }
            }
        } else {
            Label("ISLET", systemImage: "drop.fill")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Text(state.unit.label)
            if let delta = state.formattedDelta {
                Text("·")
                Text(delta).monospacedDigit()
            }
            Text("·")
            Text(state.date, style: .time)
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .foregroundStyle(.secondary)
    }
}

// MARK: - Previews

private extension GlucoseActivityState {
    static func preview(alerts: [AlertKind], offsetHours: Double = 0) -> GlucoseActivityState {
        var settings = IsletSettings()
        settings.alerts.high = 200
        let readings = DemoData.readings(endingAt: Date(timeIntervalSince1970: 1_700_000_000 + offsetHours * 3600), hours: 3)
        return GlucoseActivityState(readings: readings, settings: settings, alerts: alerts)!
    }
}

#Preview("Lock Screen", as: .content, using: GlucoseActivityAttributes()) {
    GlucoseLiveActivity()
} contentStates: {
    GlucoseActivityState.preview(alerts: [.high, .risingFast])
    GlucoseActivityState.preview(alerts: [.low], offsetHours: 3)
}

#Preview("Island expanded", as: .dynamicIsland(.expanded), using: GlucoseActivityAttributes()) {
    GlucoseLiveActivity()
} contentStates: {
    GlucoseActivityState.preview(alerts: [.high])
}

#Preview("Island compact", as: .dynamicIsland(.compact), using: GlucoseActivityAttributes()) {
    GlucoseLiveActivity()
} contentStates: {
    GlucoseActivityState.preview(alerts: [.high])
}
