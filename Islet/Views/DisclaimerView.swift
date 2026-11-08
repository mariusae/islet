import IsletKit
import SwiftUI

/// Shown once before anything else: Islet is not a medical device and must not replace the Dexcom app.
enum Disclaimer {
    static let storageKey = "disclaimer.acceptedVersion"
    /// Bump when the wording changes materially, so everyone sees and accepts it again.
    static let version = 1

    static let points: [(symbol: String, title: String, body: String)] = [
        ("cross.case", "Not for treatment decisions",
         "Islet is not a medical device. Never dose insulin, eat or otherwise treat based on what Islet shows. Confirm with your Dexcom app, receiver or a fingerstick first, and trust your symptoms over any number."),
        ("bell.slash", "Don't rely on its alerts",
         "Islet's Live Activities can arrive late or not at all. They depend on Dexcom Share, your network, Islet's push server and iOS, and any of these can fail without warning."),
        ("iphone.radiowaves.left.and.right", "Keep the Dexcom app",
         "The Dexcom app, with its alerts turned on, remains your CGM app. Don't turn off, silence or delete it because you use Islet."),
        ("exclamationmark.bubble", "Unofficial",
         "Islet isn't made, endorsed or supported by Dexcom. It reads an undocumented interface that can change or stop working at any time."),
    ]
}

struct DisclaimerView: View {
    @AppStorage(Disclaimer.storageKey) private var acceptedVersion = 0
    @State private var understood = false

    var body: some View {
        ZStack {
            Backdrop(color: Palette.urgentLow)

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    DisclaimerPoints()
                }
                .padding(.horizontal, 24)
                .padding(.top, 48)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom) { acknowledgement }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Palette.urgentLow)
            Text("Islet is not a medical device")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text("It's a convenience for glancing at your glucose. It does not replace the Dexcom app or its alarms.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private var acknowledgement: some View {
        VStack(spacing: 14) {
            Toggle(isOn: $understood.animation(.snappy)) {
                Text("I understand Islet is not a medical device, and I'll keep using the Dexcom app and its alerts.")
                    .font(.subheadline.weight(.medium))
            }
            .toggleStyle(CheckboxToggleStyle())

            Button {
                acceptedVersion = Disclaimer.version
            } label: {
                Text("Continue")
                    .font(.system(.headline, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Palette.accent, in: Capsule())
                    .foregroundStyle(Theme.onAccent)
                    .opacity(understood ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .disabled(!understood)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .background(.bar)
    }
}

/// The disclaimer's points, also shown from Settings.
struct DisclaimerPoints: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(Disclaimer.points, id: \.title) { point in
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: point.symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Palette.urgentLow)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(point.title)
                            .font(.system(.headline, design: .rounded))
                        Text(point.body)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

private struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22))
                    .foregroundStyle(configuration.isOn ? Palette.accent : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                configuration.label
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

/// Settings page that repeats the disclaimer.
struct DisclaimerDetailView: View {
    var body: some View {
        ScrollView {
            DisclaimerPoints()
                .padding(24)
        }
        .background(Theme.groupedBackground)
        .navigationTitle("Not a Medical Device")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    DisclaimerView()
}
