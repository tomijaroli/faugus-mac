import Foundation

/// Sort modes of the main window (`sort_map` in upstream `launcher.py`). The persisted value in
/// `config.json` is the raw string; an unknown value falls back to `alpha`.
public enum SortMode: String, CaseIterable, Sendable {
    case alpha, playtime, lastplayed, custom

    public init(configValue: String) {
        self = SortMode(rawValue: configValue) ?? .alpha
    }

    /// The msgid upstream shows on the sort button.
    public var label: String {
        switch self {
        case .alpha: "Alphabetical"
        case .playtime: "Playtime"
        case .lastplayed: "Last played"
        case .custom: "Custom"
        }
    }
}

/// The category filter. `config.json` stores `all`, `uncategorized` or the category name.
public enum CategorySelection: Hashable, Sendable {
    case all
    case uncategorized
    case named(String)

    public init(configValue: String) {
        switch configValue {
        case "all", "": self = .all
        case "uncategorized": self = .uncategorized
        default: self = .named(configValue)
        }
    }

    public var configValue: String {
        switch self {
        case .all: "all"
        case .uncategorized: "uncategorized"
        case let .named(n): n
        }
    }
}

extension Game {
    /// `category` as a list: a string is one category, a list is itself, anything else (upstream
    /// stores `False`) is none.
    public var categoryNames: [String] {
        switch category {
        case let .string(s): [s]
        case let .array(a): a.compactMap(\.stringValue)
        default: []
        }
    }
}

/// Port of the sort / filter logic of upstream's `sort_games`, `carrousel_visible_games`,
/// `game_in_category` and `game_matches_filter`.
public enum LibraryOrdering {
    /// Upstream's `_("None")`. A game whose only category is the literal "None" counts as
    /// uncategorized.
    public static func gameInCategory(
        _ game: Game, _ selection: CategorySelection, noneLabel: String = "None"
    ) -> Bool {
        let cats = game.categoryNames
        switch selection {
        case .all: return true
        case .uncategorized: return cats.isEmpty || cats == [noneLabel]
        case let .named(name): return (cats.isEmpty ? [noneLabel] : cats).contains(name)
        }
    }

    /// `game_matches_filter`. `search` is matched case-insensitively against the title.
    public static func matches(
        _ game: Game, search: String, category: CategorySelection, categoriesEnabled: Bool,
        noneLabel: String = "None"
    ) -> Bool {
        if !search.isEmpty, !game.title.lowercased().contains(search.lowercased()) {
            return false
        }
        if categoriesEnabled, category != .all {
            return gameInCategory(game, category, noneLabel: noneLabel)
        }
        return true
    }

    /// Primary key by mode, ties broken by lowercased title. Playtime is descending, last played
    /// is most recent first with never-played games last, custom uses `custom-order.json`
    /// positions (missing games last).
    public static func sorted(_ games: [Game], mode: SortMode, customOrder: [String: Int] = [:]) -> [Game] {
        let byTitle: (Game, Game) -> Bool = { $0.title.lowercased() < $1.title.lowercased() }
        switch mode {
        case .alpha:
            return games.sorted(by: byTitle)
        case .playtime:
            return games.sorted { a, b in
                a.playtime != b.playtime ? a.playtime > b.playtime : byTitle(a, b)
            }
        case .lastplayed:
            func key(_ g: Game) -> Double {
                GameFormatting.parseISO(g.lastPlayed).map { -$0.timeIntervalSince1970 } ?? .infinity
            }
            return games.sorted { a, b in
                let ka = key(a), kb = key(b)
                return ka != kb ? ka < kb : byTitle(a, b)
            }
        case .custom:
            return games.sorted { a, b in
                let ia = customOrder[a.gameID] ?? 999_999, ib = customOrder[b.gameID] ?? 999_999
                return ia != ib ? ia < ib : byTitle(a, b)
            }
        }
    }

    /// Sorted then filtered, the list shown in the main window.
    public static func visible(
        _ games: [Game], mode: SortMode, customOrder: [String: Int] = [:], search: String = "",
        category: CategorySelection = .all, categoriesEnabled: Bool = false, noneLabel: String = "None"
    ) -> [Game] {
        sorted(games, mode: mode, customOrder: customOrder).filter {
            matches($0, search: search, category: category, categoriesEnabled: categoriesEnabled, noneLabel: noneLabel)
        }
    }

    /// `_count_games_in_category`: the number shown next to each category in the picker.
    public static func count(_ games: [Game], in selection: CategorySelection, noneLabel: String = "None") -> Int {
        if selection == .all {
            return games.count
        }
        return games.filter { gameInCategory($0, selection, noneLabel: noneLabel) }.count
    }
}
