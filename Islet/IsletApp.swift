import SwiftUI
import IsletKit

@main
struct IsletApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let store = GlucoseStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                store.startPolling()
            case .background:
                store.stopPolling()
                GlucoseStore.scheduleBackgroundRefresh()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(GlucoseStore.refreshTaskID)) {
            await GlucoseStore.shared.handleBackgroundRefresh()
        }
    }
}

struct RootView: View {
    @Environment(GlucoseStore.self) private var store
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    var body: some View {
        ZStack {
            if store.mode == .signedOut {
                LoginView()
                    .transition(.opacity)
            } else {
                DashboardView()
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.4), value: store.mode)
        // Set on the window rather than with preferredColorScheme, which leaves open sheets in the
        // old appearance when switching back to System.
        .onChange(of: appearance, initial: true) { _, value in value.apply() }
    }
}
