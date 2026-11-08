import IsletKit
import SwiftUI
import UIKit

/// The user's appearance choice. Defaults to following the system.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearance"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    private var style: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    /// Apply to every window; presented sheets and menus follow their window.
    @MainActor func apply() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.overrideUserInterfaceStyle = style }
        }
    }
}

/// Neutral chrome colors that adapt to light and dark appearance. Range colors live in `Palette`.
enum Theme {
    static let background = Color.adaptive(light: Color(red: 0.955, green: 0.962, blue: 0.972),
                                           dark: Color(red: 0.035, green: 0.04, blue: 0.055))
    static let groupedBackground = Color.adaptive(light: Color(red: 0.945, green: 0.95, blue: 0.962),
                                                  dark: Color(red: 0.05, green: 0.055, blue: 0.07))
    /// Card surfaces.
    static let card = Color.adaptive(light: .white.opacity(0.85), dark: .white.opacity(0.045))
    static let cardStroke = Color.adaptive(light: .black.opacity(0.05), dark: .white.opacity(0.07))
    /// Text fields on the sign-in screen.
    static let field = Color.adaptive(light: .white, dark: .white.opacity(0.06))
    static let fieldStroke = Color.adaptive(light: .black.opacity(0.06), dark: .white.opacity(0.08))
    /// Chips, tracks and secondary buttons.
    static let fill = Color.adaptive(light: .black.opacity(0.05), dark: .white.opacity(0.06))
    /// The selected segment in a custom picker.
    static let selection = Color.adaptive(light: .white, dark: .white.opacity(0.14))
    static let hairline = Color.adaptive(light: .black.opacity(0.08), dark: .white.opacity(0.06))
    /// Content on an accent-colored button.
    static let onAccent = Color.adaptive(light: .white, dark: .black)
    /// Grid lines and axis labels.
    static let grid = Color.primary.opacity(0.07)
    static let axisLabel = Color.primary.opacity(0.4)
    /// Glucose shown without fresh data.
    static let stale = Color.primary.opacity(0.42)
}
