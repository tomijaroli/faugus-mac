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
        var defaultValues = JSONObject()
        let enabled: JSONValue = "True"
        let disabled: JSONValue = "False"
        defaultValues["auto-close-on-launch"] = disabled
        defaultValues["default-prefix"] = .string(paths.prefixesDirectory)
        defaultValues["mangohud"] = disabled
        defaultValues["gamemode"] = disabled
        defaultValues["discord-rpc-enabled"] = disabled
        defaultValues["sdl-enabled"] = disabled
        defaultValues["no-sleep-enabled"] = disabled
        defaultValues["default-runner"] = .string(defaultRunner)
        defaultValues["lossless-location"] = ""
        defaultValues["gpu"] = ""
        defaultValues["splash-window-enabled"] = enabled
        defaultValues["system-tray"] = disabled
        defaultValues["autostart-enabled"] = disabled
        defaultValues["mono-icon"] = disabled
        defaultValues["interface-mode"] = "List"
        defaultValues["labels-enabled"] = disabled
        defaultValues["zoom-enabled"] = disabled
        defaultValues["auto-create-shortcuts"] = disabled
        defaultValues["wayland-driver"] = disabled
        defaultValues["wow64-enabled"] = disabled
        defaultValues["language"] = .string(language)
        defaultValues["show-hidden"] = disabled
        defaultValues["automatic-updates"] = enabled
        defaultValues["show-donate"] = enabled
        defaultValues["donate-last"] = ""
        defaultValues["playtime"] = .int(0)
        defaultValues["gamepad-navigation"] = disabled
        defaultValues["minimized-startup-enabled"] = disabled
        defaultValues["categories-enabled"] = disabled
        defaultValues["auto-hide-enabled"] = disabled
        defaultValues["sort-enabled"] = disabled
        defaultValues["header-bar"] = disabled
        defaultValues["backup-auto-enabled"] = disabled
        defaultValues["backup-frequency"] = "daily"
        defaultValues["backup-target-day"] = "0"
        defaultValues["backup-dest-dir"] = ""
        defaultValues["backup-last-date"] = ""
        defaultValues["startup-window-size"] = "None"
        defaultValues["interface-theme"] = "system"
        defaultValues["accent-mode"] = "system"
        defaultValues["accent-color"] = "rgb(61,174,233)"
        defaultValues["theme-engine"] = "adwaita"
        defaultValues["steamgriddb-api-key"] = ""
        defaultValues["steamgriddb-enabled"] = disabled
        defaultValues["background-mode"] = "default"
        defaultValues["overview-color-mode"] = "default"
        defaultValues["widget-color-mode"] = "default"
        defaultValues["background-color"] = "rgb(61,174,233)"
        defaultValues["overview-color"] = "rgb(61,174,233)"
        defaultValues["banner-enabled"] = enabled
        defaultValues["grid-position"] = "Middle"
        defaultValues["grid-orientation"] = "Vertical"
        defaultValues["grid-max-children-enabled"] = disabled
        defaultValues["grid-max-children-per-line"] = "20"
        defaultValues["overview-enabled"] = disabled
        defaultValues["width"] = "1280"
        defaultValues["height"] = "720"
        defaultValues["cover-size"] = "100"
        defaultValues["sort"] = "alpha"
        defaultValues["category"] = "all"
        defaultValues["steam-user"] = "all"
        defaultValues["interface-sounds-enabled"] = disabled
        defaultValues["interface-sounds-theme"] = "cloud"
        defaultValues["interface-sounds-volume"] = "50"
        defaultValues["interface-sounds-custom-navigate"] = ""
        defaultValues["interface-sounds-custom-confirm"] = ""
        defaultValues["interface-sounds-custom-cancel"] = ""
        defaultValues["interface-sounds-custom-warning"] = ""
        return defaultValues
    }

    public let paths: FaugusPaths
    public private(set) var values: JSONObject
    private let defaultKeys: Set<String>

    /// Mac-only keys: accepted by `setValue`, never added automatically to an existing file.
    private static let macExtensionKeys: Set<String> = [macGraphicsBackendKey]

    /// `load_config`: read the file (missing/invalid is `{}`), add any missing default keys and
    /// save when something was added or the file did not exist.
    public static func load(paths: FaugusPaths, language: String? = nil) throws -> FaugusConfig {
        let languageCode = language ?? SystemLocale.currentCode()
        let defaults = defaults(paths: paths, language: languageCode)
        var configuration = FaugusConfig(paths: paths, values: defaults, existing: nil)

        let loaded = JSONFile.load(paths.configFile, default: .object(JSONObject()))
        var existing = loaded.objectValue ?? JSONObject()

        var updated = false
        for (key, value) in defaults.pairs where existing[key] == nil {
            existing[key] = value
            updated = true
        }
        configuration.values = existing
        if updated || !FileManager.default.fileExists(atPath: paths.configFile) {
            try configuration.save()
        }
        return configuration
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
        case let .string(text)?: text
        case let .int(integer)?: String(integer)
        case let .double(number)?: "\(number)"
        case let .bool(flag)?: flag ? "True" : "False"
        default: fallback
        }
    }

    /// Upstream checks `config.get(key, 'False') == 'True'`.
    public func bool(_ key: String) -> Bool {
        values[key]?.stringValue == "True"
    }

    public func int(_ key: String, default fallback: Int = 0) -> Int {
        guard let storedValue = values[key] else { return fallback }
        switch storedValue {
        case let .int(integer): return Int(integer)
        case let .double(number): return Int(number)
        case let .string(text): return Int(text) ?? fallback
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
        let backend = string(FaugusConfig.macGraphicsBackendKey)
        return backend.isEmpty ? FaugusConfig.defaultMacGraphicsBackend : backend
    }

    /// `resolve_game_runner` for the `Default` choice.
    public var defaultRunner: String {
        string("default-runner").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}
