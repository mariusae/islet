import ActivityKit
import Foundation
import IsletKit
import Observation
import os

/// Talks to the Islet push server (see `server/`), which polls Dexcom and drives the Live Activity
/// over APNs so alerts appear even when the app isn't running. Also forwards ActivityKit push tokens.
@MainActor @Observable
final class ServerSync {
    struct Status: Decodable, Equatable {
        struct Reading: Decodable, Equatable { var t: Int; var v: Int }
        struct ActivityInfo: Decodable, Equatable { var running: Bool; var hasToken: Bool? }
        struct Push: Decodable, Equatable { var at: Int; var event: String; var status: Int; var reason: String? }

        var registered: Bool
        var polling: Bool?
        var lastPollAt: Int?
        var lastReading: Reading?
        var activity: ActivityInfo?
        var hasPushToStartToken: Bool?
        var lastPush: Push?
        var error: String?
    }

    var serverURL: String {
        didSet { defaults.set(serverURL, forKey: Keys.url) }
    }

    var apiKey: String {
        didSet { Keychain.saveString(apiKey, account: Keys.apiKey) }
    }

    private(set) var status: Status?
    private(set) var lastError: String?
    private(set) var isBusy = false

    /// Server mode is on once a URL and key are configured.
    var isConfigured: Bool { endpoint != nil && !apiKey.isEmpty }

    let deviceID: String

    private var pushToStartToken: String?
    private var settingsTask: Task<Void, Never>?
    private var observers: [Task<Void, Never>] = []
    private var observedActivities: Set<String> = []
    private let defaults = UserDefaults.standard
    private let log = Logger(subsystem: "Islet", category: "server")

    private enum Keys {
        static let url = "server.url"
        static let apiKey = "server.apiKey"
        static let deviceID = "server.deviceID"
    }

    #if DEBUG
    private let environment = "sandbox"
    #else
    private let environment = "production"
    #endif

    init() {
        // Values entered in Settings win; otherwise fall back to the ones built in from Config/Local.xcconfig.
        let stored = defaults.string(forKey: Keys.url) ?? ""
        serverURL = stored.isEmpty ? Self.builtIn.url : stored
        let storedKey = Keychain.loadString(account: Keys.apiKey) ?? ""
        apiKey = storedKey.isEmpty ? Self.builtIn.apiKey : storedKey
        if let id = defaults.string(forKey: Keys.deviceID) {
            deviceID = id
        } else {
            deviceID = UUID().uuidString.lowercased()
            defaults.set(deviceID, forKey: Keys.deviceID)
        }
    }

    /// Push-server defaults from Info.plist (set through the git-ignored Config/Local.xcconfig).
    private static let builtIn: (url: String, apiKey: String) = {
        func value(_ key: String) -> String {
            (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        let host = value("IsletServerHost")
        return (host.isEmpty ? "" : "https://\(host)", value("IsletAPIKey"))
    }()

    private var endpoint: URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https" || url.host == "localhost" else { return nil }
        return url.appending(path: "v1/devices/\(deviceID)")
    }

    // MARK: Token observation

    /// Start forwarding push-to-start tokens and per-activity update tokens. Safe to call repeatedly.
    func startObserving() {
        guard observers.isEmpty else { return }
        observers.append(Task { [weak self] in
            for await data in Activity<GlucoseActivityAttributes>.pushToStartTokenUpdates {
                guard let self else { return }
                let token = data.hexString
                self.pushToStartToken = token
                await self.patch(["pushToStartToken": token])
            }
        })
        observers.append(Task { [weak self] in
            for await activity in Activity<GlucoseActivityAttributes>.activityUpdates {
                self?.observe(activity)
            }
        })
        for activity in Activity<GlucoseActivityAttributes>.activities {
            observe(activity)
        }
    }

    private func observe(_ activity: Activity<GlucoseActivityAttributes>) {
        let id = activity.id
        guard observedActivities.insert(id).inserted else { return }

        // Only one glucose activity should exist; a push-started one supersedes any older ones.
        let others = Activity<GlucoseActivityAttributes>.activities.filter { $0.id != id && $0.activityState == .active }
        if activity.activityState == .active, !others.isEmpty {
            Task { await Self.end(ids: others.map(\.id)) }
        }

        let tokens = activity.pushTokenUpdates
        let states = activity.activityStateUpdates
        observers.append(Task { [weak self] in
            for await data in tokens {
                await self?.patch(["activity": ["id": id, "token": data.hexString]])
            }
        })
        observers.append(Task { [weak self] in
            for await state in states where state == .dismissed || state == .ended {
                guard let self else { return }
                self.observedActivities.remove(id)
                // Dismissed from the Lock Screen: the user doesn't want it for these alerts.
                await self.patch(["activity": NSNull(), "suppress": state == .dismissed])
                return
            }
        })
    }

    nonisolated private static func end(ids: [String]) async {
        for activity in Activity<GlucoseActivityAttributes>.activities where ids.contains(activity.id) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    // MARK: API

    /// Register (or re-register) this device with the server. Validates the Dexcom credentials server-side.
    func register(credentials: DexcomCredentials, settings: IsletSettings) async {
        guard isConfigured else { return }
        var body: [String: Any] = [
            "credentials": [
                "username": credentials.username,
                "password": credentials.password,
                "region": credentials.region.rawValue,
            ],
            "settings": Self.json(settings),
            "environment": environment,
        ]
        if let pushToStartToken { body["pushToStartToken"] = pushToStartToken }
        await send("PUT", body: body)
    }

    /// Debounced: steppers fire rapidly.
    func updateSettings(_ settings: IsletSettings) {
        guard isConfigured else { return }
        settingsTask?.cancel()
        settingsTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await self?.patch(["settings": Self.json(settings)])
        }
    }

    func setPinned(_ pinned: Bool) async {
        await patch(["pinned": pinned])
    }

    func activityEndedByUser() async {
        await patch(["activity": NSNull(), "suppress": true])
    }

    func refreshStatus() async {
        await send("GET", body: nil)
    }

    func unregister() async {
        guard isConfigured else { return }
        await send("DELETE", body: nil)
        status = nil
    }

    private func patch(_ body: [String: Any]) async {
        guard isConfigured else { return }
        await send("PATCH", body: body)
    }

    private func send(_ method: String, body: [String: Any]?) async {
        guard let endpoint else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 204 { lastError = nil; return }
            if (200..<300).contains(code) {
                status = try? JSONDecoder().decode(Status.self, from: data)
                lastError = nil
            } else {
                let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                lastError = message ?? "Server returned HTTP \(code)"
                if code == 404 { status = Status(registered: false) }
            }
        } catch {
            log.error("\(method) failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    private static func json(_ settings: IsletSettings) -> Any {
        (try? JSONEncoder().encode(settings)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:]
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
