import IsletKit
import SwiftUI

struct SettingsView: View {
    @Environment(GlucoseStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmSignOut = false

    var body: some View {
        @Bindable var store = store
        let unit = store.settings.unit
        let step = unit == .mgdL ? 5 : 2

        NavigationStack {
            Form {
                Section {
                    Picker("Units", selection: $store.settings.unit) {
                        ForEach(GlucoseUnit.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())

                    ValueStepper(title: "Target low", color: Palette.low, value: $store.settings.targetLow,
                                 range: 60...120, step: step, unit: unit)
                    ValueStepper(title: "Target high", color: Palette.high, value: $store.settings.targetHigh,
                                 range: 120...250, step: step, unit: unit)
                } header: {
                    Text("Display")
                } footer: {
                    Text("The target range shades the chart and drives time-in-range.")
                }

                Section {
                    AlertRow(title: "Urgent low", symbol: AlertKind.urgentLow.symbol, color: Palette.urgentLow,
                             isOn: $store.settings.alerts.urgentLowEnabled) {
                        ValueStepper(title: "Below", value: $store.settings.alerts.urgentLow,
                                     range: 40...70, step: step, unit: unit)
                    }
                    AlertRow(title: "Low", symbol: AlertKind.low.symbol, color: Palette.low,
                             isOn: $store.settings.alerts.lowEnabled) {
                        ValueStepper(title: "Below", value: $store.settings.alerts.low,
                                     range: 55...120, step: step, unit: unit)
                    }
                    AlertRow(title: "High", symbol: AlertKind.high.symbol, color: Palette.high,
                             isOn: $store.settings.alerts.highEnabled) {
                        ValueStepper(title: "Above", value: $store.settings.alerts.high,
                                     range: 120...400, step: unit == .mgdL ? 10 : 4, unit: unit)
                    }
                    AlertRow(title: "Falling fast", symbol: AlertKind.fallingFast.symbol, color: Palette.low,
                             isOn: $store.settings.alerts.fallingEnabled) {
                        RateStepper(value: $store.settings.alerts.fallRate, unit: unit)
                    }
                    AlertRow(title: "Rising fast", symbol: AlertKind.risingFast.symbol, color: Palette.high,
                             isOn: $store.settings.alerts.risingEnabled) {
                        RateStepper(value: $store.settings.alerts.riseRate, unit: unit)
                    }
                } header: {
                    Text("Alert conditions")
                } footer: {
                    Text("When any enabled condition is met, Islet shows a Live Activity on your Lock Screen, in the Dynamic Island and on Apple Watch. Rates are measured over the last 15 minutes; Dexcom's single arrow is about \(unit == .mgdL ? "2 mg/dL" : "0.11 mmol/L") per minute.")
                }

                Section {
                    Picker("Keep showing after it clears", selection: $store.settings.alerts.clearAfterMinutes) {
                        ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    Toggle("Always show", isOn: $store.settings.alerts.alwaysOn)
                } header: {
                    Text("Live Activity")
                } footer: {
                    Text("“Always show” keeps the Live Activity running even when nothing is wrong. iOS ends Live Activities after 8 hours.")
                }

                if case .live = store.mode {
                    PushServerSection()
                }

                Section("Account") {
                    switch store.mode {
                    case let .live(username, region):
                        LabeledContent("Dexcom account", value: username)
                        LabeledContent("Region", value: region.displayName)
                    case .demo:
                        LabeledContent("Mode", value: "Demo data")
                    case .signedOut:
                        EmptyView()
                    }
                    Button(store.mode == .demo ? "Exit Demo" : "Sign Out", role: .destructive) {
                        confirmSignOut = true
                    }
                }

                Section {
                    Text("Islet uses Dexcom Share, an unofficial and undocumented API that can change without notice. Readings may be delayed or missing. Islet is not a medical device and isn't affiliated with Dexcom; always confirm with your CGM before making treatment decisions.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.05, green: 0.055, blue: 0.07))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Sign out of Islet?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button(store.mode == .demo ? "Exit Demo" : "Sign Out", role: .destructive) {
                    store.signOut()
                    dismiss()
                }
            }
        }
    }
}

private struct AlertRow<Detail: View>: View {
    let title: String
    let symbol: String
    let color: Color
    @Binding var isOn: Bool
    @ViewBuilder var detail: Detail

    var body: some View {
        Toggle(isOn: $isOn.animation(.snappy)) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(color)
            }
        }
        .tint(color)
        if isOn {
            detail
                .padding(.leading, 40)
        }
    }
}

private struct ValueStepper: View {
    let title: String
    var color: Color? = nil
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: GlucoseUnit

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            HStack {
                if let color {
                    Circle().fill(color).frame(width: 8, height: 8)
                }
                Text(title)
                Spacer()
                Text("\(unit.format(value)) \(unit.label)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct RateStepper: View {
    @Binding var value: Double
    let unit: GlucoseUnit

    var body: some View {
        Stepper(value: $value, in: 1...5, step: 0.5) {
            HStack {
                Text("Faster than")
                Spacer()
                Text(unit.formatRate(value).replacingOccurrences(of: "+", with: ""))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Configure the Islet push server (Cloudflare Worker in `server/`) and show its health.
private struct PushServerSection: View {
    @Environment(GlucoseStore.self) private var store

    var body: some View {
        @Bindable var server = store.server

        Section {
            TextField("https://islet.example.workers.dev", text: $server.serverURL)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("API key", text: $server.apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                Task { await store.connectServer() }
            } label: {
                HStack {
                    Text(server.status?.registered == true ? "Reconnect" : "Connect")
                    Spacer()
                    if server.isBusy { ProgressView() }
                }
            }
            .disabled(!server.isConfigured || server.isBusy)

            if let status = server.status, status.registered {
                LabeledContent("Polling Dexcom", value: status.polling == true ? "Yes" : "Stopped")
                if let reading = status.lastReading {
                    LabeledContent("Last reading") {
                        Text(Date(timeIntervalSince1970: TimeInterval(reading.t)), style: .relative)
                            + Text(" ago")
                    }
                }
                LabeledContent("Push-to-start", value: status.hasPushToStartToken == true ? "Ready" : "Waiting for token")
                if let push = status.lastPush {
                    LabeledContent("Last push") {
                        Text("\(push.event) · \(push.status == 200 ? "delivered" : (push.reason ?? "HTTP \(push.status)"))")
                    }
                }
            }
            if let error = server.lastError ?? server.status?.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Palette.low)
            }
        } header: {
            Text("Push server")
        } footer: {
            Text("With a push server, Islet's alerts reach your Lock Screen and Apple Watch even when the app isn't running: the server polls Dexcom and starts and updates the Live Activity over Apple Push. Your Dexcom credentials are sent to it and stored encrypted. Without one, Live Activities only update while Islet is open or refreshing in the background.")
        }
        .task { await server.refreshStatus() }
    }
}
