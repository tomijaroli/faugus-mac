import Foundation

/// `GAME_FIELDS` from upstream `faugus/utils.py` (2.5.6), in upstream order.
public let gameFields: [String] = [
    "gameid", "title", "path", "prefix",
    "launch_arguments", "game_arguments",
    "mangohud", "gamemode", "sdl_enabled",
    "runner",
    "addapp_enabled", "addapp", "addapp_bat", "addapp_delay", "addapp_first",
    "cover",
    "lossless_enabled", "lossless_multiplier", "lossless_flow",
    "lossless_performance", "lossless_hdr", "lossless_present",
    "playtime", "hidden", "no_sleep", "category", "icon",
    "steamgriddb_id", "pre_launch", "post_launch",
    "steam_user", "disable_umu", "runtime", "last_played", "discord_rpc",
]

/// Per-game graphics backend (Mac extension, plan §4). A missing value is never backfilled.
public enum GraphicsBackend: String, CaseIterable, Sendable {
    case `default`, dxvk, wined3d
    case wined3dVulkan = "wined3d-vulkan"
    case dxmt, d3dmetal
}

/// One entry of `games.json`.
///
/// The raw JSON object is kept, so unknown fields (including fields written by newer upstream
/// versions, or by the Mac-only `graphics` key) survive a load/save cycle. Upstream's `Game`
/// only knows `GAME_FIELDS` and silently drops everything else; the port is deliberately
/// stricter about not losing user data.
public struct Game: Equatable, Sendable, Identifiable {
    public private(set) var raw: JSONObject

    public var id: String { gameID }

    /// `Game(**prepare_game_kwargs(data))`
    public init(json: JSONObject) {
        var o = json
        for f in gameFields where o[f] == nil {
            o[f] = Game.defaultValue(for: f)
        }
        self.raw = o
    }

    public init(gameID: String, title: String) {
        var o = JSONObject()
        for f in gameFields { o[f] = Game.defaultValue(for: f) }
        o["gameid"] = .string(gameID)
        o["title"] = .string(title)
        o["runner"] = "Default"
        self.raw = o
    }

    static func defaultValue(for field: String) -> JSONValue {
        switch field {
        case "playtime": return .int(0)
        case "hidden", "no_sleep", "category": return .bool(false)
        default: return .string("")
        }
    }

    // MARK: String fields

    private func str(_ key: String) -> String {
        switch raw[key] {
        case .string(let s)?: return s
        case .int(let i)?: return String(i)
        case .double(let d)?: return "\(d)"
        default: return ""
        }
    }

    private mutating func set(_ key: String, _ value: String) { raw[key] = .string(value) }

    public var gameID: String { get { str("gameid") } set { set("gameid", newValue) } }
    public var title: String { get { str("title") } set { set("title", newValue) } }
    public var path: String { get { str("path") } set { set("path", newValue) } }
    public var prefix: String { get { str("prefix") } set { set("prefix", newValue) } }
    public var launchArguments: String { get { str("launch_arguments") } set { set("launch_arguments", newValue) } }
    public var gameArguments: String { get { str("game_arguments") } set { set("game_arguments", newValue) } }
    public var runner: String { get { str("runner") } set { set("runner", newValue) } }
    public var addApp: String { get { str("addapp") } set { set("addapp", newValue) } }
    public var addAppBat: String { get { str("addapp_bat") } set { set("addapp_bat", newValue) } }
    public var addAppDelay: String { get { str("addapp_delay") } set { set("addapp_delay", newValue) } }
    public var addAppFirst: String { get { str("addapp_first") } set { set("addapp_first", newValue) } }
    public var cover: String { get { str("cover") } set { set("cover", newValue) } }
    public var icon: String { get { str("icon") } set { set("icon", newValue) } }
    public var steamGridDBID: String { get { str("steamgriddb_id") } set { set("steamgriddb_id", newValue) } }
    public var preLaunch: String { get { str("pre_launch") } set { set("pre_launch", newValue) } }
    public var postLaunch: String { get { str("post_launch") } set { set("post_launch", newValue) } }
    public var steamUser: String { get { str("steam_user") } set { set("steam_user", newValue) } }
    public var runtime: String { get { str("runtime") } set { set("runtime", newValue) } }
    public var lastPlayed: String { get { str("last_played") } set { set("last_played", newValue) } }

    // MARK: Flags (Python truthiness on loosely typed JSON)

    private func flag(_ key: String) -> Bool { raw[key]?.isTruthy ?? false }

    public var mangohud: Bool { get { flag("mangohud") } set { raw["mangohud"] = .bool(newValue) } }
    public var gamemode: Bool { get { flag("gamemode") } set { raw["gamemode"] = .bool(newValue) } }
    public var sdlEnabled: Bool { get { flag("sdl_enabled") } set { raw["sdl_enabled"] = .bool(newValue) } }
    public var discordRPC: Bool { get { flag("discord_rpc") } set { raw["discord_rpc"] = .bool(newValue) } }
    public var disableUMU: Bool { get { flag("disable_umu") } set { raw["disable_umu"] = .bool(newValue) } }
    public var addAppEnabled: Bool { get { flag("addapp_enabled") } set { raw["addapp_enabled"] = .bool(newValue) } }
    public var hidden: Bool { get { flag("hidden") } set { raw["hidden"] = .bool(newValue) } }
    public var noSleep: Bool { get { flag("no_sleep") } set { raw["no_sleep"] = .bool(newValue) } }

    /// Seconds played.
    public var playtime: Int {
        get {
            switch raw["playtime"] {
            case .int(let i)?: return Int(i)
            case .double(let d)?: return Int(d)
            case .string(let s)?: return Int(s) ?? 0
            default: return 0
            }
        }
        set { raw["playtime"] = .int(Int64(newValue)) }
    }

    /// Upstream stores `False` or a category list/string; the port keeps whatever is there.
    public var category: JSONValue {
        get { raw["category"] ?? .bool(false) }
        set { raw["category"] = newValue }
    }

    // MARK: Mac extensions

    /// `nil` means "not set", which resolves to the `mac-graphics-backend` config value.
    public var graphics: GraphicsBackend? {
        get { raw["graphics"]?.stringValue.flatMap(GraphicsBackend.init(rawValue:)) }
        set {
            if let newValue { raw["graphics"] = .string(newValue.rawValue) } else { raw["graphics"] = nil }
        }
    }

    // MARK: Persistence

    /// `game_to_save_dict`: `GAME_FIELDS` in upstream order with upstream's normalisations,
    /// followed by any extra fields in their original order.
    public func saveObject(hidden hiddenOverride: Bool? = nil) -> JSONObject {
        var out = JSONObject()
        for f in gameFields { out[f] = raw[f] ?? Game.defaultValue(for: f) }
        out["mangohud"] = mangohud ? .bool(true) : ""
        out["gamemode"] = gamemode ? .bool(true) : ""
        out["sdl_enabled"] = sdlEnabled ? .bool(true) : ""
        out["discord_rpc"] = discordRPC ? .bool(true) : ""
        out["addapp_enabled"] = addAppEnabled ? "addapp_enabled" : ""
        out["disable_umu"] = disableUMU ? .bool(true) : ""
        if let hiddenOverride { out["hidden"] = .bool(hiddenOverride) }
        for (k, v) in raw.pairs where out[k] == nil { out[k] = v }
        return out
    }
}
