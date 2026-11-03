import AppKit
import FaugusCore
import SwiftUI

/// Colours the main window derives from `config.json` (accent, background, overview, widgets).
struct LibraryAppearance {
    let config: FaugusConfig
    let customAccent: ConfigColor?

    static func swiftUI(_ color: ConfigColor) -> Color {
        Color(.sRGB, red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255)
    }

    var accent: Color {
        customAccent.map(Self.swiftUI) ?? .accentColor
    }

    /// `get_background_rgb`: `custom` uses its colour, any other mode the accent.
    var backgroundTint: Color? {
        switch config.string("background-mode", default: "default") {
        case "custom": Self.swiftUI(ConfigColor(config.string("background-color")) ?? .fallback)
        case "accent": accent
        default: nil
        }
    }

    /// `get_overview_rgb`. Dominant colour needs artwork and falls back to the accent.
    var overviewColor: Color {
        switch config.string("overview-color-mode", default: "default") {
        case "default": .primary
        case "custom": Self.swiftUI(ConfigColor(config.string("overview-color")) ?? .fallback)
        default: accent
        }
    }

    /// Background of a game tile (`update_widget_color_css`).
    func tileBackground(selected: Bool) -> Color {
        if selected {
            return accent.opacity(0.55)
        }
        switch config.string("widget-color-mode", default: "default") {
        case "accent": return accent.opacity(0.4)
        case "solid": return Color(nsColor: .windowBackgroundColor)
        default: return Color.primary.opacity(0.07)
        }
    }

    /// Placeholder shown where a cover is missing (`accent` at 40 percent).
    var placeholder: Color {
        accent.opacity(0.4)
    }
}

/// The window background: the default one, or the accent/custom colour faded into it
/// (`fade_rgb`: 80 percent window, 20 percent colour).
struct LibraryBackground: View {
    let appearance: LibraryAppearance

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let tint = appearance.backgroundTint {
                tint.opacity(0.2)
            }
        }
        .ignoresSafeArea()
    }
}
