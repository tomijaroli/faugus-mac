import Foundation

/// `interface-mode` and the Settings rules that depend on it
/// (`on_combobox_interface_changed` in upstream `launcher.py`).
public enum InterfaceMode: String, CaseIterable, Sendable {
    case list = "List"
    case grid = "Grid"
    case covers = "Covers"
    case carrousel = "Carrousel"

    /// Unknown values behave like upstream's default.
    public init(configValue: String) {
        self = InterfaceMode(rawValue: configValue.trimmingCharacters(in: CharacterSet(charactersIn: "\""))) ?? .list
    }

    public var label: String { rawValue }

    private var isCoversOrCarrousel: Bool { self == .covers || self == .carrousel }
    private var isGridOrCovers: Bool { self == .grid || self == .covers }

    /// Labels and zoom need covers.
    public var supportsLabelsAndZoom: Bool { isCoversOrCarrousel }
    /// The banner needs covers and SteamGridDB.
    public func supportsBanner(steamGridDBEnabled: Bool) -> Bool { isCoversOrCarrousel && steamGridDBEnabled }
    /// Position and the overview panel need anything but the list.
    public var supportsPosition: Bool { self != .list }
    public var supportsOverview: Bool { self != .list }
    public var supportsOrientation: Bool { isGridOrCovers }
    public var supportsMaxChildren: Bool { isGridOrCovers }
    public var supportsStartupWindowSize: Bool { self != .list }

    /// "Maximum Columns" scrolls vertically, "Maximum Rows" horizontally.
    public static func maxChildrenLabel(orientation: String) -> String {
        orientation == "Horizontal" ? "Maximum Rows" : "Maximum Columns"
    }
}
