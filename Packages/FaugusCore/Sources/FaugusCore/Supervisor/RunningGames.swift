import Foundation

/// `running-games.json`: `{gameid: runner pid}`; plus the stop-file contract
/// (`state/stop-<gameid>`, polled once a second by the runner).
public struct RunningGames: Sendable {
    public let paths: FaugusPaths
    public init(paths: FaugusPaths) {
        self.paths = paths
    }

    public func load() -> [String: Int32] {
        let json = JSONFile.load(paths.runningGamesFile, default: .object(JSONObject()))
        var out: [String: Int32] = [:]
        for (k, v) in json.objectValue?.pairs ?? [] {
            if let n = v.intValue {
                out[k] = Int32(truncatingIfNeeded: n)
            }
        }
        return out
    }

    public func mark(gameID: String, pid: Int32) throws {
        var o = JSONFile.load(paths.runningGamesFile, default: .object(JSONObject())).objectValue ?? JSONObject()
        o[gameID] = .int(Int64(pid))
        try JSONFile.save(.object(o), to: paths.runningGamesFile)
    }

    public func unmark(gameID: String) throws {
        var o = JSONFile.load(paths.runningGamesFile, default: .object(JSONObject())).objectValue ?? JSONObject()
        o[gameID] = nil
        try JSONFile.save(.object(o), to: paths.runningGamesFile)
    }

    /// Entries whose runner process is gone (crash, reboot) are dropped.
    @discardableResult
    public func pruneDead() -> [String] {
        var removed: [String] = []
        for (id, pid) in load() where !ProcessSpawner.isAlive(pid) {
            try? unmark(gameID: id)
            removed.append(id)
        }
        return removed
    }

    public func isRunning(_ gameID: String) -> Bool {
        guard let pid = load()[gameID] else { return false }
        return ProcessSpawner.isAlive(pid)
    }

    // MARK: Stop requests

    public func requestStop(gameID: String) throws {
        try FileManager.default.createDirectory(atPath: paths.stateDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.stopFile(gameID: gameID), contents: Data())
    }

    /// Consumes a pending stop request.
    public func consumeStopRequest(gameID: String) -> Bool {
        let p = paths.stopFile(gameID: gameID)
        guard FileManager.default.fileExists(atPath: p) else { return false }
        try? FileManager.default.removeItem(atPath: p)
        return true
    }

    public func clearStopRequest(gameID: String) {
        try? FileManager.default.removeItem(atPath: paths.stopFile(gameID: gameID))
    }
}

/// Playtime bookkeeping, matching upstream `_save_progress`.
public struct PlaytimeStore: Sendable {
    public let paths: FaugusPaths
    public init(paths: FaugusPaths) {
        self.paths = paths
    }

    /// `datetime.now().isoformat()` (microseconds, no timezone).
    public static func isoNow(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        return f.string(from: date)
    }

    public func gamePlaytime(gameID: String) -> Int {
        let entries = JSONFile.load(paths.gamesJSON).arrayValue ?? []
        for e in entries.compactMap(\.objectValue) where e["gameid"]?.stringValue == gameID {
            return Int(e["playtime"]?.intValue ?? 0)
        }
        return 0
    }

    /// Steam-type games keep their playtime in Steam; Faugus only records when it launched one.
    public func touchLastPlayed(gameID: String, now: Date = Date()) throws {
        guard !gameID.isEmpty else { return }
        var entries = try JSONFile.loadOrThrow(paths.gamesJSON).arrayValue ?? []
        for i in entries.indices {
            guard var o = entries[i].objectValue, o["gameid"]?.stringValue == gameID else { continue }
            o["last_played"] = .string(PlaytimeStore.isoNow(now))
            entries[i] = .object(o)
            break
        }
        try JSONFile.save(.array(entries), to: paths.gamesJSON)
    }

    /// Writes `playtime` and `last_played` for one game, leaving every other entry and field
    /// byte for byte as it was, and bumps the global config total.
    public func save(
        gameID: String, gameBaseline: Int, totalBaseline: Int, runtimeSeconds: Int, now: Date = Date()
    ) throws {
        guard runtimeSeconds > 0 else { return }

        var cfg = try FaugusConfig.load(paths: paths)
        // Upstream stores this through `set_value`, i.e. as a string.
        cfg.setValue("playtime", String(totalBaseline + runtimeSeconds))
        try cfg.save()

        guard !gameID.isEmpty else { return }
        var entries = try JSONFile.loadOrThrow(paths.gamesJSON).arrayValue ?? []
        for i in entries.indices {
            guard var o = entries[i].objectValue, o["gameid"]?.stringValue == gameID else { continue }
            o["playtime"] = .int(Int64(gameBaseline + runtimeSeconds))
            o["last_played"] = .string(PlaytimeStore.isoNow(now))
            entries[i] = .object(o)
            break
        }
        try JSONFile.save(.array(entries), to: paths.gamesJSON)
    }
}
