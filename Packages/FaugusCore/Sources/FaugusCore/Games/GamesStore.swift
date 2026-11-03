import Foundation

public enum GamesStoreError: Error, Equatable {
    /// `games.json` exists but is not valid JSON or not an array. Upstream refuses to touch it
    /// ("refusing to touch ..."); so does the port, to avoid destroying a recoverable file.
    case corrupt(path: String)
}

/// Port of `load_games`, `save_games` and `backup_games` from `launcher.py`.
public struct GamesStore: Sendable {
    public static let backupKeepCount = 20

    public let paths: FaugusPaths

    public init(paths: FaugusPaths) {
        self.paths = paths
    }

    /// Every entry in `games.json`, hidden included, in file order. Non-object entries are
    /// skipped.
    public func loadAll() throws -> [Game] {
        let entries = try loadEntries()
        return entries.compactMap { $0.objectValue.map(Game.init(json:)) }
    }

    /// `load_games`: hidden games are dropped unless `showHidden`; sorted by lowercased title.
    public func load(showHidden: Bool) throws -> [Game] {
        let all = try loadAll()
        let visible = showHidden ? all : all.filter { !$0.hidden }
        return visible.sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    public func existingGameIDs() throws -> Set<String> {
        try Set(loadAll().map(\.gameID))
    }

    /// `save_games`. `games` is the set currently visible in the UI; hidden games that are not
    /// in it are preserved verbatim from the file, and `deletedGameID` is dropped.
    public func save(games: [Game], deletedGameID: String? = nil, now: Date = Date()) throws {
        let entries: [JSONValue]
        do { entries = try loadEntries() } catch { throw error }

        let visibleIDs = Set(games.map(\.gameID))
        let hiddenKept: [JSONValue] = entries.filter { entry in
            guard let o = entry.objectValue else { return false }
            let id = o["gameid"]?.stringValue
            return (o["hidden"]?.isTruthy ?? false)
                && !(id.map(visibleIDs.contains) ?? false)
                && id != deletedGameID
        }

        let newEntries: [JSONValue] =
            games.filter { $0.gameID != deletedGameID }.map { .object($0.saveObject()) } + hiddenKept

        try backup(now: now)
        try JSONFile.save(.array(newEntries), to: paths.gamesJSON)
    }

    /// `backup_games`: copy to `games-backup/games-data-YYYY-MM-DD_HH-MM-SS.json`, keep 20.
    @discardableResult
    public func backup(now: Date = Date()) throws -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.gamesJSON) else { return nil }
        try fm.createDirectory(atPath: paths.gamesBackupDir, withIntermediateDirectories: true)

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dest = paths.gamesBackupDir + "/games-data-\(f.string(from: now)).json"
        if fm.fileExists(atPath: dest) {
            try fm.removeItem(atPath: dest)
        }
        try fm.copyItem(atPath: paths.gamesJSON, toPath: dest)

        var backups = try fm.contentsOfDirectory(atPath: paths.gamesBackupDir)
            .filter { $0.hasPrefix("games-data-") && $0.hasSuffix(".json") }
            .sorted()
        while backups.count > GamesStore.backupKeepCount {
            let oldest = backups.removeFirst()
            try? fm.removeItem(atPath: paths.gamesBackupDir + "/" + oldest)
        }
        return dest
    }

    // MARK: Internals

    private func loadEntries() throws -> [JSONValue] {
        let value: JSONValue
        do { value = try JSONFile.loadOrThrow(paths.gamesJSON) } catch {
            throw GamesStoreError.corrupt(path: paths.gamesJSON)
        }
        guard case let .array(a) = value else { throw GamesStoreError.corrupt(path: paths.gamesJSON) }
        return a
    }
}
