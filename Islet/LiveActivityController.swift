import ActivityKit
import Foundation
import IsletKit
import Observation
import os

/// Starts, updates, and ends the glucose Live Activity according to `ActivityPolicy`.
@MainActor @Observable
final class LiveActivityController {
    private(set) var isRunning = false
    private(set) var statusMessage: String?

    /// User asked for the activity explicitly ("Show Now"); keep it until they end it.
    private(set) var pinned: Bool {
        didSet { defaults.set(pinned, forKey: Keys.pinned) }
    }

    private var lastAlertDate: Date? {
        didSet { defaults.set(lastAlertDate, forKey: Keys.lastAlertDate) }
    }

    private(set) var lastAlerts: [AlertKind] {
        didSet { defaults.set(lastAlerts.map(\.rawValue), forKey: Keys.lastAlerts) }
    }

    /// When each alert kind was last active; an alert sounds once per episode, not on every flicker.
    private var alertHistory: [AlertKind: Date] {
        didSet {
            defaults.set(Dictionary(uniqueKeysWithValues: alertHistory.map { ($0.key.rawValue, $0.value) }),
                         forKey: Keys.alertHistory)
        }
    }

    /// Alerts the user dismissed by ending the activity; don't restart for these until they clear.
    private var suppressed: Set<AlertKind> = []

    private let defaults = UserDefaults.standard
    private let log = Logger(subsystem: "Islet", category: "live-activity")

    private enum Keys {
        static let pinned = "activity.pinned"
        static let lastAlertDate = "activity.lastAlertDate"
        static let lastAlerts = "activity.lastAlerts"
        static let alertHistory = "activity.alertHistory"
    }

    init() {
        pinned = defaults.bool(forKey: Keys.pinned)
        lastAlertDate = defaults.object(forKey: Keys.lastAlertDate) as? Date
        lastAlerts = (defaults.stringArray(forKey: Keys.lastAlerts) ?? []).compactMap(AlertKind.init(rawValue:))
        let history = defaults.dictionary(forKey: Keys.alertHistory) as? [String: Date] ?? [:]
        alertHistory = Dictionary(uniqueKeysWithValues: history.compactMap { key, date in
            AlertKind(rawValue: key).map { ($0, date) }
        })
        isRunning = current != nil
    }

    var activitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    private var current: Activity<GlucoseActivityAttributes>? {
        Activity<GlucoseActivityAttributes>.activities.first { $0.activityState == .active || $0.activityState == .stale }
    }

    /// - Parameter serverManaged: the push server starts and ends activities; locally we only
    ///   refresh a running one (and start one when the user asks explicitly).
    func sync(readings: [GlucoseReading], settings: IsletSettings, serverManaged: Bool = false, now: Date = .now) async {
        let clearAfter = TimeInterval(settings.alerts.clearAfterMinutes * 60)
        let stale = AlertEngine.isStale(readings, now: now)
        let alerts = AlertEngine.evaluate(readings, settings: settings.alerts, now: now, previous: lastAlerts)
        let running = current
        if running == nil, isRunning, pinned {
            // Dismissed from the Lock Screen, or ended by the system after its 8-hour limit.
            pinned = false
        }

        var fresh: [AlertKind] = []
        if stale {
            // Signal loss isn't recovery: keep the alert clock running so the activity stays up and still
            // lingers for the full clear-after period once readings resume.
            if running != nil, !lastAlerts.isEmpty { lastAlertDate = now }
        } else {
            if alerts.isEmpty { suppressed = [] } else { lastAlertDate = now }
            fresh = AlertEngine.announce(alerts, history: &alertHistory, now: now, clearAfter: clearAfter)
        }

        // While stale, show the last known alerts rather than none.
        guard let state = GlucoseActivityState(readings: readings, settings: settings, alerts: stale ? lastAlerts : alerts) else {
            isRunning = running != nil
            return
        }

        let decision = ActivityPolicy.decide(
            alerts: alerts,
            isRunning: running != nil,
            keepAlive: pinned || settings.alerts.alwaysOn,
            lastAlertDate: lastAlertDate,
            clearAfter: clearAfter,
            now: now,
            stale: stale)

        switch decision {
        case .start where serverManaged && !pinned:
            break
        case .end where serverManaged:
            break
        case .start:
            let onlySuppressed = !alerts.isEmpty && Set(alerts).isSubset(of: suppressed)
            if pinned || settings.alerts.alwaysOn || !onlySuppressed {
                start(state)
            }
        case .update:
            if let running {
                // With the server managing the activity, it sounds the alerts; don't double up.
                await Self.update(id: running.id, content: content(state),
                                  alert: serverManaged ? nil : alertConfiguration(state, announcing: fresh))
            }
        case .end:
            if let running {
                await Self.end(id: running.id, content: content(state))
            }
        case .none:
            break
        }

        if !stale { lastAlerts = alerts }
        isRunning = current != nil
    }

    /// Show the Live Activity now, regardless of alerts.
    func show(readings: [GlucoseReading], settings: IsletSettings, serverManaged: Bool) async {
        pinned = true
        suppressed = []
        await sync(readings: readings, settings: settings, serverManaged: serverManaged)
    }

    /// End the Live Activity. Alerts that are active right now won't bring it back until they clear or escalate.
    func stop() async {
        pinned = false
        suppressed = Set(lastAlerts)
        await Self.end(id: nil, content: nil)
        isRunning = false
    }

    private func start(_ state: GlucoseActivityState) {
        guard activitiesEnabled else {
            statusMessage = "Live Activities are turned off for Islet in Settings."
            return
        }
        do {
            _ = try Activity.request(attributes: GlucoseActivityAttributes(), content: content(state), pushType: nil)
            statusMessage = nil
        } catch {
            log.error("start failed: \(error.localizedDescription, privacy: .public)")
            statusMessage = "Couldn't start the Live Activity: \(error.localizedDescription)"
        }
    }

    private func alertConfiguration(_ state: GlucoseActivityState, announcing fresh: [AlertKind]) -> AlertConfiguration? {
        guard let top = fresh.first else { return nil }
        return AlertConfiguration(
            title: LocalizedStringResource(stringLiteral: top.title),
            body: LocalizedStringResource(stringLiteral: "\(state.formattedValue) \(state.unit.label) \(state.trend.arrow)"),
            sound: .default)
    }

    // `Activity` isn't Sendable, so these look activities up by ID outside the main actor.

    nonisolated private static func update(id: String, content: ActivityContent<GlucoseActivityState>,
                                           alert: AlertConfiguration?) async {
        for activity in Activity<GlucoseActivityAttributes>.activities where activity.id == id {
            await activity.update(content, alertConfiguration: alert)
        }
    }

    /// Ends the activity with `id`, or every Islet activity when `id` is nil.
    nonisolated private static func end(id: String?, content: ActivityContent<GlucoseActivityState>?) async {
        for activity in Activity<GlucoseActivityAttributes>.activities where id == nil || activity.id == id {
            await activity.end(content, dismissalPolicy: .immediate)
        }
    }

    private func content(_ state: GlucoseActivityState) -> ActivityContent<GlucoseActivityState> {
        ActivityContent(
            state: state,
            staleDate: state.date.addingTimeInterval(AlertEngine.staleAfter),
            relevanceScore: state.alerts.isEmpty ? 50 : 100)
    }
}
