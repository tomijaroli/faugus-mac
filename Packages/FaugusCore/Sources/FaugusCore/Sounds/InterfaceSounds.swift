import Foundation

/// The four UI sound kinds, in the order a coalesced queue prefers the later one
/// (`UI_SOUND_KINDS` / `play_ui_sound`).
public enum UISoundKind: String, CaseIterable, Sendable {
    case navigate
    case confirm
    case cancel
    case warning

    public var priority: Int {
        switch self {
        case .navigate: 0
        case .confirm: 1
        case .cancel: 2
        case .warning: 3
        }
    }

    public var settingsKey: String {
        "interface-sounds-custom-\(rawValue)"
    }
}

/// Themes shipped as `assets/sounds/<theme>-<kind>.ogg`, plus Custom.
public enum UISoundTheme: String, CaseIterable, Sendable {
    case cloud
    case glass
    case wood
    case breeze
    case kalimba
    case glow
    case hush
    case custom

    /// `Cloud (Default)` for the default theme; the rest are capitalised, Custom is translated.
    public var settingsLabel: String {
        switch self {
        case .cloud: "Cloud"
        case .custom: "Custom"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}

/// The Interface Sounds settings of `config.json`.
public struct InterfaceSoundsSettings: Equatable, Sendable {
    public var isEnabled: Bool
    public var theme: UISoundTheme
    public var volumePercent: Int
    public var customPaths: [UISoundKind: String]

    public init(
        isEnabled: Bool = false,
        theme: UISoundTheme = .cloud,
        volumePercent: Int = 50,
        customPaths: [UISoundKind: String] = [:]
    ) {
        self.isEnabled = isEnabled
        self.theme = theme
        self.volumePercent = min(100, max(0, volumePercent))
        self.customPaths = customPaths
    }

    public init(configuration: FaugusConfig) {
        let themeValue = configuration.string("interface-sounds-theme", default: "cloud")
        self.init(
            isEnabled: configuration.bool("interface-sounds-enabled"),
            theme: UISoundTheme(rawValue: themeValue) ?? .cloud,
            volumePercent: configuration.int("interface-sounds-volume", default: 50),
            customPaths: Dictionary(uniqueKeysWithValues: UISoundKind.allCases.map { kind in
                (kind, configuration.string(kind.settingsKey))
            })
        )
    }

    public func write(to configuration: inout FaugusConfig) {
        configuration.setValue("interface-sounds-enabled", bool: isEnabled)
        configuration.setValue("interface-sounds-theme", theme.rawValue)
        configuration.setValue("interface-sounds-volume", String(volumePercent))
        for kind in UISoundKind.allCases {
            configuration.setValue(kind.settingsKey, customPaths[kind] ?? "")
        }
    }

    /// Gtk.MediaFile uses `volume ** (1/3)` so the slider feels linear.
    public var playbackGain: Double {
        pow(Double(volumePercent) / 100, 1.0 / 3.0)
    }

    /// `get_ui_sound_path`: a custom file when the theme is Custom, else the bundled ogg.
    public func filePath(kind: UISoundKind, assetsDirectory: String, expand: (String) -> String) -> String {
        if theme == .custom {
            return expand(customPaths[kind] ?? "")
        }
        return assetsDirectory + "/sounds/\(theme.rawValue)-\(kind.rawValue).ogg"
    }
}

/// Coalesces overlapping `play_ui_sound` calls onto the next run-loop turn, keeping the highest
/// kind, and drops a Navigate that follows another by less than 50 ms.
public struct UISoundQueue: Equatable, Sendable {
    public static let navigateDebounce: TimeInterval = 0.05

    public private(set) var pending: UISoundKind?
    public private(set) var lastNavigateAt: TimeInterval = -.infinity

    public init() {}

    /// Returns `true` when this is the first pending kind (the caller should schedule a flush).
    public mutating func enqueue(_ kind: UISoundKind) -> Bool {
        let wasEmpty = pending == nil
        if pending == nil || kind.priority > pending!.priority {
            pending = kind
        }
        return wasEmpty
    }

    public mutating func clear() {
        pending = nil
    }

    /// Takes the pending kind, applying the Navigate debounce against `now`.
    public mutating func flush(now: TimeInterval) -> UISoundKind? {
        let kind = pending
        pending = nil
        guard let kind else { return nil }
        if kind == .navigate {
            if now - lastNavigateAt < Self.navigateDebounce {
                return nil
            }
            lastNavigateAt = now
        }
        return kind
    }
}
