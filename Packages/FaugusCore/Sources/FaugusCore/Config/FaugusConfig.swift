import Foundation

/// Port of `faugus/config_manager.py` (`ConfigManager`).
///
/// Values are kept as an order-preserving `JSONObject` so the file round-trips byte for byte.
/// Booleans are the strings `"True"` / `"False"`, exactly as upstream stores them.
public struct FaugusConfig: Equatable, Sendable {
    public static let defaultRunner = "Wine-Staging Latest"
    public static let macGraphicsBackendKey = "mac-graphics-backend"
    public static let defaultMacGraphicsBackend = "dxvk"

    /// Upstream defaults in upstream order. Exceptions (see docs/parity.md): `default-runner`,
    /// `language`.
    public static func defaults(paths: FaugusPaths, language: String) -> JSONObject {
        var o = JSONObject()
        let T: JSONValue = "True"
        let F: JSONValue = "False"
        o["auto-close-on-launch"] = F
        o["default-prefix"] = .string(paths.prefixesDir)
        o["mangohud"] = F
        o["gamemode"] = F
        o["discord-rpc-enabled"] = F
        o["sdl-enabled"] = F
        o["no-sleep-enabled"] = F
        o["default-runner"] = .string(defaultRunner)
        o["lossless-location"] = ""
        o["gpu"] = ""
        o["splash-window-enabled"] = T
        o["system-tray"] = F
        o["autostart-enabled"] = F
        o["mono-icon"] = F
        o["interface-mode"] = "List"
        o["labels-enabled"] = F
        o["zoom-enabled"] = F
        o["auto-create-shortcuts"] = F
        o["wayland-driver"] = F
        o["wow64-enabled"] = F
        o["language"] = .string(language)
        o["show-hidden"] = F
        o["automatic-updates"] = T
        o["show-donate"] = T
        o["donate-last"] = ""
        o["playtime"] = .int(0)
        o["gamepad-navigation"] = F
        o["minimized-startup-enabled"] = F
        o["categories-enabled"] = F
        o["auto-hide-enabled"] = F
        o["sort-enabled"] = F
        o["header-bar"] = F
        o["backup-auto-enabled"] = F
        o["backup-frequency"] = "daily"
        o["backup-target-day"] = "0"
        o["backup-dest-dir"] = ""
        o["backup-last-date"] = ""
        o["startup-window-size"] = "None"
        o["interface-theme"] = "system"
        o["accent-mode"] = "system"
        o["accent-color"] = "rgb(61,174,233)"
        o["theme-engine"] = "adwaita"
        o["steamgriddb-api-key"] = ""
        o["steamgriddb-enabled"] = F
        o["background-mode"] = "default"
        o["overview-color-mode"] = "default"
        o["widget-color-mode"] = "default"
        o["background-color"] = "rgb(61,174,233)"
        o["overview-color"] = "rgb(61,174,233)"
        o["banner-enabled"] = T
        o["grid-position"] = "Middle"
        o["grid-orientation"] = "Vertical"
        o["grid-max-children-enabled"] = F
        o["grid-max-children-per-line"] = "20"
        o["overview-enabled"] = F
        o["width"] = "1280"
        o["height"] = "720"
        o["cover-size"] = "100"
        o["sort"] = "alpha"
        o["category"] = "all"
        o["steam-user"] = "all"
        o["interface-sounds-enabled"] = F
        o["interface-sounds-theme"] = "cloud"
        o["interface-sounds-volume"] = "50"
        o["interface-sounds-custom-navigate"] = ""
        o["interface-sounds-custom-confirm"] = ""
        o["interface-sounds-custom-cancel"] = ""
        o["interface-sounds-custom-warning"] = ""
        return o
    }

    public let paths: FaugusPaths
    public private(set) var values: JSONObject
    private let defaultKeys: Set<String>

    /// Mac-only keys: accepted by `setValue`, never added automatically to an existing file.
    private static let macExtensionKeys: Set<String> = [macGraphicsBackendKey]

    /// `load_config`: read the file (missing/invalid is `{}`), add any missing default keys and
    /// save when something was added or the file did not exist.
    public static func load(paths: FaugusPaths, language: String? = nil) throws -> FaugusConfig {
        let lang = language ?? SystemLocale.currentCode()
        let defaults = defaults(paths: paths, language: lang)
        var cfg = FaugusConfig(paths: paths, values: defaults, existing: nil)

        let loaded = JSONFile.load(paths.configFile, default: .object(JSONObject()))
        var existing = loaded.objectValue ?? JSONObject()

        var updated = false
        for (key, value) in defaults.pairs where existing[key] == nil {
            existing[key] = value
            updated = true
        }
        cfg.values = existing
        if updated || !FileManager.default.fileExists(atPath: paths.configFile) {
            try cfg.save()
        }
        return cfg
    }

    private init(paths: FaugusPaths, values: JSONObject, existing: JSONObject?) {
        self.paths = paths
        self.values = existing ?? values
        defaultKeys = Set(FaugusConfig.defaults(paths: paths, language: "").keys)
    }

    public func save() throws {
        try JSONFile.save(.object(values), to: paths.configFile)
    }

    // MARK: Accessors

    public func string(_ key: String, default fallback: String = "") -> String {
        switch values[key] {
        case let .string(s)?: s
        case let .int(i)?: String(i)
        case let .double(d)?: "\(d)"
        case let .bool(b)?: b ? "True" : "False"
        default: fallback
        }
    }

    /// Upstream checks `config.get(key, 'False') == 'True'`.
    public func bool(_ key: String) -> Bool {
        values[key]?.stringValue == "True"
    }

    public func int(_ key: String, default fallback: Int = 0) -> Int {
        guard let v = values[key] else { return fallback }
        switch v {
        case let .int(i): return Int(i)
        case let .double(d): return Int(d)
        case let .string(s): return Int(s) ?? fallback
        default: return fallback
        }
    }

    /// `ConfigManager.set_value`: unknown keys are ignored and the value is stringified
    /// (Python `str(value)`), so `True` becomes `"True"`.
    public mutating func setValue(_ key: String, _ value: String) {
        guard defaultKeys.contains(key) || FaugusConfig.macExtensionKeys.contains(key) else { return }
        values[key] = .string(value)
    }

    public mutating func setValue(_ key: String, bool: Bool) {
        setValue(key, bool ? "True" : "False")
    }

    /// Direct typed write used for `playtime`, which upstream stores as a JSON number.
    public mutating func setRaw(_ key: String, _ value: JSONValue) {
        values[key] = value
    }

    public func accentColor() -> String {
        string("accent-mode") == "custom" ? string("accent-color") : "system"
    }

    /// Mac extension. Never backfilled into the file; reads fall back to `dxvk`.
    public var macGraphicsBackend: String {
        let v = string(FaugusConfig.macGraphicsBackendKey)
        return v.isEmpty ? FaugusConfig.defaultMacGraphicsBackend : v
    }

    /// `resolve_game_runner` for the `Default` choice.
    public var defaultRunner: String {
        string("default-runner").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}
