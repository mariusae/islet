import Foundation

/// Dexcom Share regions. Share is the (unofficial) service that powers the Dexcom Follow app;
/// it is what pydexcom, Nightscout's share bridge, and similar tools use.
public enum DexcomRegion: String, Codable, Sendable, CaseIterable, Identifiable {
    case us
    case outsideUS
    case japan

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .us: "United States"
        case .outsideUS: "Outside US"
        case .japan: "Japan"
        }
    }

    public var shortName: String {
        switch self {
        case .us: "US"
        case .outsideUS: "International"
        case .japan: "Japan"
        }
    }

    var baseURL: URL {
        switch self {
        case .us: URL(string: "https://share2.dexcom.com/ShareWebServices/Services/")!
        case .outsideUS: URL(string: "https://shareous1.dexcom.com/ShareWebServices/Services/")!
        case .japan: URL(string: "https://share.dexcom.jp/ShareWebServices/Services/")!
        }
    }

    var applicationID: String {
        switch self {
        case .us, .outsideUS: "d89443d2-327c-4a6f-89e5-496bbb0317db"
        case .japan: "d8665ade-9673-4e27-9ff6-92db4ce13d13"
        }
    }
}

public struct DexcomCredentials: Codable, Equatable, Sendable {
    public var username: String
    public var password: String
    public var region: DexcomRegion

    public init(username: String, password: String, region: DexcomRegion) {
        self.username = username
        self.password = password
        self.region = region
    }
}

public enum DexcomError: Error, LocalizedError, Equatable {
    case invalidCredentials
    case accountNotFound
    case tooManyAttempts
    case sessionInvalid
    case server(code: String, message: String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "Dexcom didn't accept that username and password."
        case .accountNotFound:
            "No Dexcom account was found with that username in this region."
        case .tooManyAttempts:
            "Too many sign-in attempts. Dexcom has temporarily locked the account; try again later."
        case .sessionInvalid:
            "The Dexcom session expired."
        case let .server(code, message):
            message.isEmpty ? "Dexcom error: \(code)" : "Dexcom error: \(message)"
        case let .badResponse(detail):
            "Unexpected response from Dexcom (\(detail))."
        }
    }
}

/// Client for the Dexcom Share web service.
///
/// Flow: `AuthenticatePublisherAccount` (username → account ID), then
/// `LoginPublisherAccountById` (account ID → session ID), then
/// `ReadPublisherLatestGlucoseValues` with the session ID. Sessions expire, so a
/// session error triggers one re-login and retry.
public actor DexcomShareClient {
    public let credentials: DexcomCredentials
    private let urlSession: URLSession
    private var accountID: String?
    private var sessionID: String?

    static let nullUUID = "00000000-0000-0000-0000-000000000000"
    public static let maxMinutes = 1440
    public static let maxCount = 288

    public init(credentials: DexcomCredentials, urlSession: URLSession = .shared) {
        self.credentials = credentials
        self.urlSession = urlSession
    }

    /// Sign in and establish a session. Throws `DexcomError` on failure.
    public func authenticate() async throws {
        let region = credentials.region
        if accountID == nil {
            let account: String = try await post(
                "General/AuthenticatePublisherAccount",
                body: [
                    "accountName": credentials.username,
                    "password": credentials.password,
                    "applicationId": region.applicationID,
                ]
            )
            guard Self.isValidID(account) else { throw DexcomError.invalidCredentials }
            accountID = account
        }
        let session: String = try await post(
            "General/LoginPublisherAccountById",
            body: [
                "accountId": accountID!,
                "password": credentials.password,
                "applicationId": region.applicationID,
            ]
        )
        guard Self.isValidID(session) else { throw DexcomError.invalidCredentials }
        sessionID = session
    }

    /// Readings from the last `minutes` minutes, oldest first.
    public func readings(minutes: Int = maxMinutes, maxCount: Int = maxCount) async throws -> [GlucoseReading] {
        if sessionID == nil { try await authenticate() }
        do {
            return try await fetchReadings(minutes: minutes, maxCount: maxCount)
        } catch DexcomError.sessionInvalid {
            sessionID = nil
            try await authenticate()
            return try await fetchReadings(minutes: minutes, maxCount: maxCount)
        }
    }

    private func fetchReadings(minutes: Int, maxCount: Int) async throws -> [GlucoseReading] {
        let raw: [ShareReading] = try await post(
            "Publisher/ReadPublisherLatestGlucoseValues",
            query: [
                URLQueryItem(name: "sessionId", value: sessionID),
                URLQueryItem(name: "minutes", value: String(min(max(minutes, 1), Self.maxMinutes))),
                URLQueryItem(name: "maxCount", value: String(min(max(maxCount, 1), Self.maxCount))),
            ],
            body: [:]
        )
        return Self.normalize(raw.compactMap(\.reading))
    }

    static func normalize(_ readings: [GlucoseReading]) -> [GlucoseReading] {
        var seen = Set<Date>()
        return readings.sorted { $0.date < $1.date }.filter { seen.insert($0.date).inserted }
    }

    private func post<T: Decodable>(_ path: String, query: [URLQueryItem] = [], body: [String: String]) async throws -> T {
        var components = URLComponents(url: credentials.region.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DexcomError.badResponse("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            if let error = try? JSONDecoder().decode(ShareErrorBody.self, from: data) {
                throw Self.map(error)
            }
            throw DexcomError.server(code: "HTTP \(http.statusCode)", message: "")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DexcomError.badResponse("could not decode \(T.self)")
        }
    }

    static func map(_ error: ShareErrorBody) -> DexcomError {
        let code = error.code ?? ""
        let message = error.message ?? ""
        switch code {
        case "SessionIdNotFound", "SessionNotValid":
            return .sessionInvalid
        case "AccountPasswordInvalid":
            return .invalidCredentials
        case "SSO_AuthenticateAccountNotFound":
            return .accountNotFound
        case _ where code.hasPrefix("SSO_AuthenticateMaxAttempts"):
            return .tooManyAttempts
        case "SSO_InternalError" where message.contains("Cannot Authenticate"):
            return .invalidCredentials
        default:
            return .server(code: code, message: message)
        }
    }

    static func isValidID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil && id != nullUUID
    }
}

struct ShareErrorBody: Decodable {
    var code: String?
    var message: String?

    enum CodingKeys: String, CodingKey {
        case code = "Code"
        case message = "Message"
    }
}

/// Raw Share reading: `{"WT":"Date(1699999999000)","ST":"...","DT":"...","Value":120,"Trend":"Flat"}`.
struct ShareReading: Decodable {
    var wt: String
    var value: Int
    var trend: Trend

    enum CodingKeys: String, CodingKey {
        case wt = "WT"
        case value = "Value"
        case trend = "Trend"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wt = try c.decode(String.self, forKey: .wt)
        value = try c.decode(Int.self, forKey: .value)
        if let s = try? c.decode(String.self, forKey: .trend) {
            trend = Trend(rawValue: s) ?? .none
        } else if let i = try? c.decode(Int.self, forKey: .trend) {
            trend = Trend(index: i)
        } else {
            trend = .none
        }
    }

    var reading: GlucoseReading? {
        guard let date = Self.parseDate(wt) else { return nil }
        return GlucoseReading(date: date, value: value, trend: trend)
    }

    /// Parses `Date(1699999999000)` or `Date(1699999999000-0500)`; the number is UTC milliseconds.
    static func parseDate(_ s: String) -> Date? {
        guard let open = s.firstIndex(of: "(") else { return nil }
        let digits = s[s.index(after: open)...].prefix { $0.isNumber }
        guard let ms = Double(digits) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}
