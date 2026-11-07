import BackgroundTasks
import Foundation
import IsletKit
import Observation
import os

/// App state: account, readings, settings, polling. Drives the Live Activity after every refresh.
@MainActor @Observable
final class GlucoseStore {
    static let shared = GlucoseStore()

    nonisolated static let refreshTaskID = (Bundle.main.bundleIdentifier ?? "islet") + ".refresh"

    enum Mode: Equatable {
        case signedOut
        case demo
        case live(username: String, region: DexcomRegion)
    }

    private(set) var mode: Mode = .signedOut
    private(set) var readings: [GlucoseReading] = []
    private(set) var isRefreshing = false
    private(set) var lastError: String?

    var settings: IsletSettings {
        didSet {
            guard settings != oldValue else { return }
            if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Keys.settings) }
            if case .live = mode { server.updateSettings(settings) }
            Task { await syncActivity() }
        }
    }

    let activity = LiveActivityController()
    let server = ServerSync()

    private var client: DexcomShareClient?
    private var pollTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private let log = Logger(subsystem: "Islet", category: "store")

    private enum Keys {
        static let settings = "settings"
        static let demo = "demoMode"
        static let cache = "readingsCache"
    }

    private init() {
        settings = defaults.data(forKey: Keys.settings)
            .flatMap { try? JSONDecoder().decode(IsletSettings.self, from: $0) } ?? IsletSettings()
        if defaults.bool(forKey: Keys.demo) {
            mode = .demo
        } else if let credentials = Keychain.load() {
            client = DexcomShareClient(credentials: credentials)
            mode = .live(username: credentials.username, region: credentials.region)
            readings = defaults.data(forKey: Keys.cache)
                .flatMap { try? JSONDecoder().decode([GlucoseReading].self, from: $0) } ?? []
        }
        server.startObserving()
    }

    /// The push server owns the Live Activity lifecycle when it's configured for a real account.
    var isServerManaged: Bool {
        if case .live = mode { return server.isConfigured }
        return false
    }

    var latest: GlucoseReading? { readings.last }

    var alerts: [AlertKind] { AlertEngine.evaluate(readings, settings: settings.alerts, previous: activity.lastAlerts) }

    // MARK: Account

    func signIn(username: String, password: String, region: DexcomRegion) async throws {
        let credentials = DexcomCredentials(
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            region: region)
        let client = DexcomShareClient(credentials: credentials)
        try await client.authenticate()
        try Keychain.save(credentials)
        await server.register(credentials: credentials, settings: settings)
        defaults.set(false, forKey: Keys.demo)
        self.client = client
        readings = []
        lastError = nil
        mode = .live(username: credentials.username, region: region)
        startPolling()
    }

    func startDemo() {
        defaults.set(true, forKey: Keys.demo)
        client = nil
        readings = []
        lastError = nil
        mode = .demo
        startPolling()
    }

    func signOut() {
        stopPolling()
        if case .live = mode { Task { [server] in await server.unregister() } }
        Keychain.delete()
        defaults.set(false, forKey: Keys.demo)
        defaults.removeObject(forKey: Keys.cache)
        client = nil
        readings = []
        lastError = nil
        mode = .signedOut
        Task { await activity.stop() }
    }

    // MARK: Refresh

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            switch mode {
            case .signedOut:
                return
            case .demo:
                readings = DemoData.readings()
            case .live:
                guard let client else { return }
                readings = try await fetch(using: client)
                if let data = try? JSONEncoder().encode(readings) { defaults.set(data, forKey: Keys.cache) }
            }
            lastError = nil
        } catch {
            log.error("refresh failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        await syncActivity()
    }

    private func syncActivity() async {
        await activity.sync(readings: readings, settings: settings, serverManaged: isServerManaged)
    }

    // MARK: Live Activity actions

    func showActivity() async {
        await activity.show(readings: readings, settings: settings, serverManaged: isServerManaged)
        if isServerManaged { await server.setPinned(true) }
    }

    func endActivity() async {
        await activity.stop()
        if isServerManaged { await server.activityEndedByUser() }
    }

    // MARK: Push server

    /// Register with the push server using the stored Dexcom credentials (after configuring it in Settings).
    func connectServer() async {
        guard server.isConfigured, case .live = mode, let credentials = Keychain.load() else { return }
        await server.register(credentials: credentials, settings: settings)
        await syncActivity()
    }

    /// On foreground: refresh server status, re-registering if the server lost this device.
    private func checkServer() async {
        guard isServerManaged else { return }
        await server.refreshStatus()
        if server.status?.registered == false { await connectServer() }
    }

    /// Fetch only what's new when we already have recent history, then merge and trim to 24 hours.
    private func fetch(using client: DexcomShareClient) async throws -> [GlucoseReading] {
        let now = Date.now
        var minutes = DexcomShareClient.maxMinutes
        if let last = readings.last, now.timeIntervalSince(last.date) < 3 * 3600, readings.count > 12 {
            minutes = Int(now.timeIntervalSince(last.date) / 60) + 15
        }
        let fresh = try await client.readings(minutes: minutes)
        var byDate = Dictionary(readings.map { ($0.date, $0) }, uniquingKeysWith: { _, b in b })
        for r in fresh { byDate[r.date] = r }
        let cutoff = now.addingTimeInterval(-24 * 3600)
        return byDate.values.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
    }

    func startPolling() {
        guard mode != .signedOut else { return }
        Task { await checkServer() }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(self.nextPollDelay()))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Dexcom publishes every 5 minutes; poll just after the next reading is due, retrying every 30s if late.
    private func nextPollDelay() -> TimeInterval {
        guard let latest else { return 60 }
        let due = latest.date.addingTimeInterval(5 * 60 + 20).timeIntervalSinceNow
        return due > 5 ? min(due, 300) : 30
    }

    // MARK: Background

    func handleBackgroundRefresh() async {
        Self.scheduleBackgroundRefresh()
        await refresh()
    }

    nonisolated static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = .now.addingTimeInterval(5 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
