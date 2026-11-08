import IsletKit
import SwiftUI

struct LiveActivityCard: View {
    @Environment(GlucoseStore.self) private var store

    private var activity: LiveActivityController { store.activity }
    private var alerts: AlertSettings { store.settings.alerts }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Palette.accent.opacity(0.16))
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Live Activity")
                        .font(.system(.headline, design: .rounded))
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if activity.isRunning {
                    Circle()
                        .fill(Palette.inRange)
                        .frame(width: 8, height: 8)
                        .shadow(color: Palette.inRange, radius: 4)
                        .padding(.top, 6)
                }
            }

            FlowRow(items: armedConditions)

            Button {
                Task {
                    if activity.isRunning {
                        await store.endActivity()
                    } else {
                        await store.showActivity()
                    }
                }
            } label: {
                Text(activity.isRunning ? "End Live Activity" : "Show Now")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        activity.isRunning ? AnyShapeStyle(Theme.fill) : AnyShapeStyle(Palette.accent.opacity(0.9)),
                        in: Capsule())
                    .foregroundStyle(activity.isRunning ? Color.primary : Theme.onAccent)
            }
            .buttonStyle(.plain)
            .disabled(store.readings.isEmpty)

            if let message = activity.statusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Palette.low)
            } else if !activity.activitiesEnabled {
                Text("Live Activities are turned off for Islet. Enable them in Settings › Islet.")
                    .font(.footnote)
                    .foregroundStyle(Palette.low)
            }
        }
        .card()
    }

    private var statusText: String {
        if activity.isRunning {
            return store.alerts.isEmpty
                ? "On your Lock Screen, Dynamic Island and Apple Watch."
                : "Showing \(store.alerts.map(\.title).joined(separator: " · ")) on your Lock Screen and Apple Watch."
        }
        if alerts.alwaysOn { return "Always on — starts with the next reading." }
        return "Appears automatically when any of these happen:"
    }

    private var armedConditions: [(String, Color)] {
        let unit = store.settings.unit
        var items: [(String, Color)] = []
        if alerts.urgentLowEnabled { items.append(("Below \(unit.format(alerts.urgentLow))", Palette.urgentLow)) }
        if alerts.lowEnabled { items.append(("Below \(unit.format(alerts.low))", Palette.low)) }
        if alerts.highEnabled { items.append(("Above \(unit.format(alerts.high))", Palette.high)) }
        if alerts.fallingEnabled { items.append(("Falling \(unit.formatRate(alerts.fallRate).replacingOccurrences(of: "+", with: ""))", Palette.low)) }
        if alerts.risingEnabled { items.append(("Rising \(unit.formatRate(alerts.riseRate).replacingOccurrences(of: "+", with: ""))", Palette.high)) }
        return items
    }
}

/// Wrapping row of small condition chips.
struct FlowRow: View {
    let items: [(String, Color)]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: 5) {
                    Circle().fill(items[i].1).frame(width: 6, height: 6)
                    Text(items[i].0)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Theme.fill, in: Capsule())
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
