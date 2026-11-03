import Foundation

/// A game in the tray menu: what is shown and what launching it needs.
public struct TrayGameEntry: Equatable, Sendable {
    public var gameID: String
    public var title: String
    public var lastPlayed: String
}

/// The recent-games part of the tray menu (`TrayIcon.rebuild_menu` in upstream `tray_sni.py`).
public enum TrayEntries {
    /// Upstream shows at most five games.
    public static let recentLimit = 5

    /// Games that have a `gameid` and a `last_played`, newest first. Upstream sorts the tuples
    /// `(last_played, gameid, title, path)` in reverse, so equal timestamps order by game id,
    /// descending. Hidden games are included, as upstream reads `games.json` directly.
    public static func recentGames(from games: [Game], limit: Int = recentLimit) -> [TrayGameEntry] {
        let candidates = games.compactMap { game -> (
            lastPlayed: String,
            gameID: String,
            title: String,
            path: String
        )? in
            guard !game.gameID.isEmpty, !game.lastPlayed.isEmpty else { return nil }
            return (game.lastPlayed, game.gameID, game.title.isEmpty ? game.gameID : game.title, game.path)
        }
        let newestFirst = candidates.sorted { first, second in
            if first.lastPlayed != second.lastPlayed {
                return first.lastPlayed > second.lastPlayed
            }
            if first.gameID != second.gameID {
                return first.gameID > second.gameID
            }
            if first.title != second.title {
                return first.title > second.title
            }
            return first.path > second.path
        }
        return newestFirst.prefix(limit).map {
            TrayGameEntry(gameID: $0.gameID, title: $0.title, lastPlayed: $0.lastPlayed)
        }
    }
}
