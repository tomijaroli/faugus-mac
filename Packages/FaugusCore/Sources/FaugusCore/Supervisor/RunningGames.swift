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
        var processIDs: [String: Int32] = [:]
        for (gameID, value) in json.objectValue?.pairs ?? [] {
            if let processID = value.intValue {
                processIDs[gameID] = Int32(truncatingIfNeeded: processID)
            }
        }
        return processIDs
    }

    public func mark(gameID: String, pid: Int32) throws {
        var runningObject = JSONFile.load(paths.runningGamesFile, default: .object(JSONObject()))
            .objectValue ?? JSONObject()
        runningObject[gameID] = .int(Int64(pid))
        try JSONFile.save(.object(runningObject), to: paths.runningGamesFile)
    }

    public func unmark(gameID: String) throws {
        var runningObject = JSONFile.load(paths.runningGamesFile, default: .object(JSONObject()))
            .objectValue ?? JSONObject()
        runningObject[gameID] = nil
        try JSONFile.save(.object(runningObject), to: paths.runningGamesFile)
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
        try FileManager.default.createDirectory(atPath: paths.stateDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.stopFile(gameID: gameID), contents: Data())
    }

    /// Consumes a pending stop request.
    public func consumeStopRequest(gameID: String) -> Bool {
        let stopFilePath = paths.stopFile(gameID: gameID)
        guard FileManager.default.fileExists(atPath: stopFilePath) else { return false }
        try? FileManager.default.removeItem(atPath: stopFilePath)
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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        return formatter.string(from: date)
    }

    public func gamePlaytime(gameID: String) -> Int {
        let entries = JSONFile.load(paths.gamesJSON).arrayValue ?? []
        for entry in entries.compactMap(\.objectValue) where entry["gameid"]?.stringValue == gameID {
            return Int(entry["playtime"]?.intValue ?? 0)
        }
        return 0
    }

    /// Steam-type games keep their playtime in Steam; Faugus only records when it launched one.
    public func touchLastPlayed(gameID: String, now: Date = Date()) throws {
        guard !gameID.isEmpty else { return }
        var entries = try JSONFile.loadOrThrow(paths.gamesJSON).arrayValue ?? []
        for index in entries.indices {
            guard var entry = entries[index].objectValue, entry["gameid"]?.stringValue == gameID else { continue }
            entry["last_played"] = .string(PlaytimeStore.isoNow(now))
            entries[index] = .object(entry)
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

        var configuration = try FaugusConfig.load(paths: paths)
        // Upstream stores this through `set_value`, i.e. as a string.
        configuration.setValue("playtime", String(totalBaseline + runtimeSeconds))
        try configuration.save()

        guard !gameID.isEmpty else { return }
        var entries = try JSONFile.loadOrThrow(paths.gamesJSON).arrayValue ?? []
        for index in entries.indices {
            guard var entry = entries[index].objectValue, entry["gameid"]?.stringValue == gameID else { continue }
            entry["playtime"] = .int(Int64(gameBaseline + runtimeSeconds))
            entry["last_played"] = .string(PlaytimeStore.isoNow(now))
            entries[index] = .object(entry)
            break
        }
        try JSONFile.save(.array(entries), to: paths.gamesJSON)
    }
}
