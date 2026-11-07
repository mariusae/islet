import Foundation
import Testing
@testable import IsletKit

@Suite struct ShareParsingTests {
    @Test func parsesStringTrends() throws {
        let json = """
        [{"WT":"Date(1699999800000)","ST":"Date(1699999800000)","DT":"Date(1699999800000-0500)","Value":142,"Trend":"FortyFiveUp"},
         {"WT":"Date(1699999500000)","ST":"Date(1699999500000)","DT":"Date(1699999500000-0500)","Value":131,"Trend":"Flat"}]
        """
        let raw = try JSONDecoder().decode([ShareReading].self, from: Data(json.utf8))
        let readings = DexcomShareClient.normalize(raw.compactMap(\.reading))
        #expect(readings.map(\.value) == [131, 142])
        #expect(readings.last?.trend == .fortyFiveUp)
        #expect(readings.last?.date == Date(timeIntervalSince1970: 1_699_999_800))
    }

    @Test func parsesIntegerTrends() throws {
        let json = #"[{"WT":"Date(1699999800000)","Value":90,"Trend":6}]"#
        let raw = try JSONDecoder().decode([ShareReading].self, from: Data(json.utf8))
        #expect(raw.first?.trend == .singleDown)
    }

    @Test func mapsErrors() {
        #expect(DexcomShareClient.map(.init(code: "SessionNotValid", message: nil)) == .sessionInvalid)
        #expect(DexcomShareClient.map(.init(code: "AccountPasswordInvalid", message: nil)) == .invalidCredentials)
        #expect(DexcomShareClient.map(.init(code: "SSO_AuthenticateMaxAttemptsExceeed", message: nil)) == .tooManyAttempts)
        #expect(!DexcomShareClient.isValidID("00000000-0000-0000-0000-000000000000"))
        #expect(DexcomShareClient.isValidID("e3b0c442-98fc-1c14-9afb-f4c8996fb924"))
    }
}

@Suite struct AlertTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func series(_ values: [Int]) -> [GlucoseReading] {
        values.enumerated().map { i, v in
            GlucoseReading(date: now.addingTimeInterval(Double(i - values.count + 1) * 300), value: v, trend: .flat)
        }
    }

    @Test func detectsLowAndUrgentLow() {
        let s = AlertSettings()
        #expect(AlertEngine.evaluate(series([80, 75, 68]), settings: s, now: now).contains(.low))
        let urgent = AlertEngine.evaluate(series([60, 56, 52]), settings: s, now: now)
        #expect(urgent.first == .urgentLow)
        #expect(!urgent.contains(.low))
    }

    @Test func detectsRapidChanges() {
        let s = AlertSettings()
        #expect(AlertEngine.evaluate(series([100, 112, 125, 138]), settings: s, now: now) == [.risingFast])
        #expect(AlertEngine.evaluate(series([150, 138, 126, 114]), settings: s, now: now) == [.fallingFast])
        #expect(AlertEngine.evaluate(series([120, 121, 119, 120]), settings: s, now: now).isEmpty)
    }

    @Test func ignoresStaleData() {
        let readings = series([40, 40, 40])
        #expect(AlertEngine.evaluate(readings, settings: AlertSettings(), now: now.addingTimeInterval(3600)).isEmpty)
    }

    @Test func prioritizesAlerts() {
        var s = AlertSettings()
        s.high = 150
        #expect(AlertEngine.evaluate(series([140, 152, 164, 176]), settings: s, now: now) == [.high, .risingFast])
    }

    @Test func activityLifecycle() {
        let clear: TimeInterval = 20 * 60
        #expect(ActivityPolicy.decide(alerts: [.high], isRunning: false, keepAlive: false, lastAlertDate: now, clearAfter: clear, now: now) == .start)
        #expect(ActivityPolicy.decide(alerts: [.high], isRunning: true, keepAlive: false, lastAlertDate: now, clearAfter: clear, now: now) == .update)
        #expect(ActivityPolicy.decide(alerts: [], isRunning: true, keepAlive: false, lastAlertDate: now.addingTimeInterval(-600), clearAfter: clear, now: now) == .update)
        #expect(ActivityPolicy.decide(alerts: [], isRunning: true, keepAlive: false, lastAlertDate: now.addingTimeInterval(-1800), clearAfter: clear, now: now) == .end)
        #expect(ActivityPolicy.decide(alerts: [], isRunning: false, keepAlive: false, lastAlertDate: nil, clearAfter: clear, now: now) == .none)
        #expect(ActivityPolicy.decide(alerts: [], isRunning: false, keepAlive: true, lastAlertDate: nil, clearAfter: clear, now: now) == .start)
    }

    @Test func holdsRunningActivityThroughSignalLoss() {
        let clear: TimeInterval = 20 * 60
        #expect(ActivityPolicy.decide(alerts: [], isRunning: true, keepAlive: false, lastAlertDate: now.addingTimeInterval(-3600),
                                      clearAfter: clear, now: now, stale: true) == .update)
        #expect(ActivityPolicy.decide(alerts: [], isRunning: false, keepAlive: false, lastAlertDate: nil,
                                      clearAfter: clear, now: now, stale: true) == .none)
    }

    @Test func needsMarginBeforeClearing() {
        var s = AlertSettings()
        s.high = 220
        #expect(AlertEngine.evaluate(series([225, 223, 219]), settings: s, now: now, previous: [.high]) == [.high])
        #expect(AlertEngine.evaluate(series([225, 223, 214]), settings: s, now: now, previous: [.high]).isEmpty)
        #expect(AlertEngine.evaluate(series([214, 216, 219]), settings: s, now: now).isEmpty)
        let d = AlertSettings()
        #expect(AlertEngine.evaluate(series([66, 68, 72]), settings: d, now: now, previous: [.low]) == [.low])
        #expect(AlertEngine.evaluate(series([66, 70, 76]), settings: d, now: now, previous: [.low]).isEmpty)
        #expect(AlertEngine.evaluate(series([50, 54, 57]), settings: d, now: now, previous: [.urgentLow]).first == .urgentLow)
        #expect(AlertEngine.evaluate(series([52, 58, 62]), settings: d, now: now, previous: [.urgentLow]) == [.low])
        // Rising at ~1.7 mg/dL/min: below the 2.0 threshold, but within the 0.5 margin once active.
        #expect(AlertEngine.evaluate(series([100, 108, 117, 125]), settings: d, now: now, previous: [.risingFast]) == [.risingFast])
        #expect(AlertEngine.evaluate(series([100, 108, 117, 125]), settings: d, now: now).isEmpty)
    }

    @Test func announcesOncePerEpisode() {
        let clear: TimeInterval = 20 * 60
        var history: [AlertKind: Date] = [:]
        #expect(AlertEngine.announce([.high], history: &history, now: now, clearAfter: clear) == [.high])
        // Flickers off and back on within the clear-after period: quiet.
        #expect(AlertEngine.announce([.high], history: &history, now: now.addingTimeInterval(600), clearAfter: clear).isEmpty)
        // A new kind still sounds.
        #expect(AlertEngine.announce([.high, .risingFast], history: &history, now: now.addingTimeInterval(900), clearAfter: clear) == [.risingFast])
        // Clear for the full period, then back: a new episode.
        #expect(AlertEngine.announce([.high], history: &history, now: now.addingTimeInterval(900 + clear), clearAfter: clear) == [.high])
        // Recovering from urgent low through low stays quiet.
        var low: [AlertKind: Date] = [:]
        _ = AlertEngine.announce([.urgentLow], history: &low, now: now, clearAfter: clear)
        #expect(AlertEngine.announce([.low], history: &low, now: now.addingTimeInterval(300), clearAfter: clear).isEmpty)
    }

    @Test func activityStateFitsInPayload() throws {
        let readings = DemoData.readings(endingAt: now, hours: 24)
        let state = try #require(GlucoseActivityState(readings: readings, settings: IsletSettings(), alerts: [.high]))
        #expect(state.history.count == 25)
        #expect(try JSONEncoder().encode(state).count < 2048)
    }

    /// The server builds this JSON by hand; keep the wire format pinned.
    @Test func activityStateDecodesServerJSON() throws {
        let json = #"{"value":182,"trend":"SingleUp","timestamp":1700000000,"delta":7,"alerts":["high","risingFast"],"unit":"mgdL","targetLow":70,"targetHigh":180,"urgentLow":55,"history":[{"m":5,"v":175},{"m":0,"v":182}]}"#
        let state = try JSONDecoder().decode(GlucoseActivityState.self, from: Data(json.utf8))
        #expect(state.value == 182)
        #expect(state.trend == .singleUp)
        #expect(state.date == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(state.alerts == [.high, .risingFast])
        let noDelta = #"{"value":90,"trend":"Flat","timestamp":1700000000,"alerts":[],"unit":"mmolL","targetLow":70,"targetHigh":180,"urgentLow":55,"history":[]}"#
        #expect(try JSONDecoder().decode(GlucoseActivityState.self, from: Data(noDelta.utf8)).delta == nil)
    }

    @Test func settingsDecodeWithMissingKeys() throws {
        let decoded = try JSONDecoder().decode(IsletSettings.self, from: Data(#"{"unit":"mmolL","alerts":{"high":200}}"#.utf8))
        #expect(decoded.unit == .mmolL)
        #expect(decoded.alerts.high == 200)
        #expect(decoded.alerts.low == 70)
        #expect(decoded.targetHigh == 180)
    }
}

@Suite struct FormattingTests {
    @Test func formatsUnits() {
        #expect(GlucoseUnit.mgdL.format(123) == "123")
        #expect(GlucoseUnit.mmolL.format(126) == "7.0")
        #expect(GlucoseUnit.mgdL.format(39) == "LOW")
        #expect(GlucoseUnit.mgdL.formatDelta(4) == "+4")
        #expect(GlucoseUnit.mgdL.formatDelta(-3) == "−3")
        #expect(GlucoseUnit.mgdL.formatDelta(0) == "±0")
    }

    @Test func demoDataCoversRanges() {
        let readings = DemoData.readings(endingAt: Date(timeIntervalSince1970: 1_700_000_000), hours: 24)
        #expect(readings.count == 288)
        #expect(readings.contains { $0.value < 70 })
        #expect(readings.contains { $0.value > 180 })
    }
}
