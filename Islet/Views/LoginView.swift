import IsletKit
import SwiftUI

struct LoginView: View {
    @Environment(GlucoseStore.self) private var store

    @State private var username = ""
    @State private var password = ""
    @State private var region: DexcomRegion = .us
    @State private var isSigningIn = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case username, password }

    private let demoTrace: [SparkPoint] = {
        let readings = DemoData.readings(endingAt: Date(timeIntervalSince1970: 1_700_020_000), hours: 6)
        guard let last = readings.last else { return [] }
        return readings.map { SparkPoint(m: Int(last.date.timeIntervalSince($0.date) / 60), v: $0.value) }
    }()

    var body: some View {
        ZStack {
            Backdrop(color: Palette.inRange)

            SparklineView(points: demoTrace, low: 70, high: 180, span: 360, lineWidth: 3, showsBand: false)
                .frame(height: 220)
                .opacity(0.22)
                .blur(radius: 0.5)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 70)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            ScrollView {
                VStack(spacing: 28) {
                    header
                        .padding(.top, 150)
                    form
                    footer
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Text("Islet")
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(colors: [.white, Palette.inRange.opacity(0.85)], startPoint: .top, endPoint: .bottom))
            Text("Your glucose, at a glance —\nand front and center when it matters.")
                .font(.system(.callout, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private var form: some View {
        VStack(spacing: 14) {
            VStack(spacing: 0) {
                field(icon: "person.fill") {
                    TextField("Dexcom username or email", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .submitLabel(.next)
                        .focused($focus, equals: .username)
                        .onSubmit { focus = .password }
                }
                Divider().overlay(.white.opacity(0.06)).padding(.leading, 48)
                field(icon: "lock.fill") {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focus, equals: .password)
                        .onSubmit(signIn)
                }
            }
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08)))

            Picker("Region", selection: $region) {
                ForEach(DexcomRegion.allCases) { Text($0.shortName).tag($0) }
            }
            .pickerStyle(.segmented)

            if let error {
                Text(error)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Palette.low)
                    .multilineTextAlignment(.center)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Button(action: signIn) {
                ZStack {
                    if isSigningIn {
                        ProgressView().tint(.black)
                    } else {
                        Text("Sign In")
                    }
                }
                .font(.system(.headline, design: .rounded))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(
                    LinearGradient(colors: [Palette.inRange, Palette.accent], startPoint: .leading, endPoint: .trailing),
                    in: Capsule())
                .foregroundStyle(.black)
                .opacity(canSubmit ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .padding(.top, 4)

            Button("Explore with demo data") {
                store.startDemo()
            }
            .font(.system(.subheadline, design: .rounded).weight(.medium))
            .foregroundStyle(Palette.accent)
            .padding(.top, 2)
        }
        .animation(.snappy, value: error)
    }

    private var footer: some View {
        Text("Islet reads from Dexcom Share, the service behind the Dexcom Follow app. Turn on Share in your Dexcom app and invite at least one follower. Your password is stored only in this device's Keychain.\n\nIslet isn't affiliated with Dexcom and isn't a medical device — confirm with your CGM receiver or app before treating.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
    }

    private func field<Content: View>(icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 20)
            content()
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
    }

    private var canSubmit: Bool {
        !isSigningIn && !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    private func signIn() {
        guard canSubmit else { return }
        focus = nil
        isSigningIn = true
        error = nil
        Task {
            defer { isSigningIn = false }
            do {
                try await store.signIn(username: username, password: password, region: region)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

#Preview {
    LoginView()
        .environment(GlucoseStore.shared)
        .preferredColorScheme(.dark)
}
