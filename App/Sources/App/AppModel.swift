import AppKit
import FaugusCore
import Foundation
import Observation

/// Shared state for the launcher UI: paths, config, translations and the games list.
@MainActor
@Observable
final class AppModel {
    let paths: FaugusPaths
    private(set) var config: FaugusConfig?
    private(set) var games: [Game] = []
    private(set) var translator: Translator = .identity
    private(set) var languageCode: String = "en_US"
    private(set) var loadError: String?
    /// `gameid -> runner pid`, refreshed once per second and on `refresh-menu`.
    private(set) var running: [String: Int32] = [:]
    private(set) var actionError: String?

    var isRightToLeft: Bool { LanguageCatalogs.isRightToLeft(languageCode) }

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var notificationToken: NSObjectProtocol?

    init(paths: FaugusPaths = .live) {
        self.paths = paths
        reload()
        startPolling()
    }

    // MARK: Loading

    func reload() {
        do {
            try paths.ensureDirectories()
            let cfg = try FaugusConfig.load(paths: paths)
            config = cfg
            // `FAUGUS_LANG` is a QA override that never touches config.json.
            languageCode = ProcessInfo.processInfo.environment["FAUGUS_LANG"] ?? cfg.string("language", default: "en_US")
            translator = Self.languageCatalogs()?.translator(for: languageCode) ?? .identity
            games = try GamesStore(paths: paths).load(showHidden: cfg.bool("show-hidden"))
            running = RunningGames(paths: paths).load()
            loadError = nil
        } catch {
            loadError = "\(error)"
        }
    }

    private func startPolling() {
        notificationToken = DistributedNotificationCenter.default().addObserver(
            forName: .faugusRefreshMenu, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let paths = self.paths
                let previous = self.running
                let current = await Task.detached { () -> [String: Int32] in
                    let store = RunningGames(paths: paths)
                    _ = store.pruneDead()
                    return store.load()
                }.value
                if current != previous {
                    self.running = current
                    // A game ended: playtime and last_played changed on disk.
                    if current.count < previous.count || Set(previous.keys) != Set(current.keys) { self.reload() }
                }
            }
        }
    }

    /// `Contents/Resources/languages`, or `FAUGUS_LANGUAGES_DIR` when running unbundled.
    static func languageCatalogs() -> LanguageCatalogs? {
        if let override = ProcessInfo.processInfo.environment["FAUGUS_LANGUAGES_DIR"] {
            return LanguageCatalogs(localeDir: URL(fileURLWithPath: override))
        }
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("languages"),
            FileManager.default.fileExists(atPath: dir.path)
        else { return nil }
        return LanguageCatalogs(localeDir: dir)
    }

    // MARK: Running games

    func isRunning(_ game: Game) -> Bool { running[game.gameID] != nil }

    /// Spawns `Faugus --game <id> [--logs]` in its own session, so quitting the launcher never
    /// stops a game (upstream behaviour; plan section 5).
    func play(_ game: Game, withLogs: Bool) {
        if isRunning(game) { stop(game); return }
        guard let exe = Bundle.main.executablePath ?? CommandLine.arguments.first else { return }
        var argv = [exe, "--game", game.gameID]
        if withLogs { argv.append("--logs") }
        let gameDir = (paths.expand(game.path) as NSString).deletingLastPathComponent
        var isDir: ObjCBool = false
        let cwd = FileManager.default.fileExists(atPath: gameDir, isDirectory: &isDir) && isDir.boolValue ? gameDir : nil
        do {
            _ = try ProcessSpawner.spawn(
                argv: argv,
                options: .init(workingDirectory: cwd, environment: ProcessInfo.processInfo.environment, newSession: true))
            actionError = nil
            updateLastPlayedOrdering(game)
        } catch {
            actionError = "\(error)"
        }
    }

    func stop(_ game: Game) {
        try? RunningGames(paths: paths).requestStop(gameID: game.gameID)
    }

    private func updateLastPlayedOrdering(_ game: Game) {
        // Upstream records `latest-games.json`; that arrives with the full library (P2).
    }

    // MARK: Editing

    func existingIDs() -> Set<String> {
        (try? GamesStore(paths: paths).existingGameIDs()) ?? []
    }

    /// Adds or replaces a game (matched on `gameid`) and writes games.json.
    func save(_ game: Game) {
        var all = (try? GamesStore(paths: paths).loadAll()) ?? []
        if let i = all.firstIndex(where: { $0.gameID == game.gameID }) {
            all[i] = game
        } else {
            all.append(game)
        }
        write(all, deleted: nil)
    }

    /// Removes the game entry. With `removePrefix` the prefix goes to the Trash (never `rm`),
    /// and only when no other game uses it.
    func delete(_ game: Game, removePrefix: Bool) {
        let all = ((try? GamesStore(paths: paths).loadAll()) ?? []).filter { $0.gameID != game.gameID }
        write(all, deleted: game.gameID)
        guard removePrefix else { return }
        let prefix = paths.expand(game.prefix)
        let shared = all.contains { paths.expand($0.prefix) == prefix }
        if !shared, !prefix.isEmpty, FileManager.default.fileExists(atPath: prefix) {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: prefix), resultingItemURL: nil)
            } catch {
                actionError = "\(translator("Failed to remove prefix")): \(error.localizedDescription)"
            }
        }
    }

    /// Other games sharing this game's prefix (upstream warns before deleting).
    func gamesSharingPrefix(with game: Game) -> Int {
        let prefix = paths.expand(game.prefix)
        return games.filter { $0.gameID != game.gameID && paths.expand($0.prefix) == prefix }.count
    }

    func duplicate(_ game: Game) {
        let ids = existingIDs()
        let newTitle = game.title + " (copy)"
        var copy = game
        let newID = GameID.unique(base: GameID.format(title: newTitle), existing: ids)
        copy.gameID = newID
        copy.title = newTitle
        // A game with its own prefix under the default prefix folder gets a fresh one.
        let base = paths.expand(config?.string("default-prefix", default: paths.prefixesDir) ?? paths.prefixesDir)
        if (paths.expand(game.prefix) as NSString).deletingLastPathComponent == base {
            copy.prefix = base + "/" + newID
        }
        copy.playtime = 0
        copy.lastPlayed = ""
        save(copy)
    }

    func toggleHidden(_ game: Game) {
        var g = game
        g.hidden.toggle()
        save(g)
    }

    private func write(_ all: [Game], deleted: String?) {
        do {
            try GamesStore(paths: paths).save(games: all, deletedGameID: deleted)
            actionError = nil
        } catch {
            actionError = "\(error)"
        }
        reload()
    }

    // MARK: Finder

    func revealGameLocation(_ game: Game) {
        let dir = (paths.expand(game.path) as NSString).deletingLastPathComponent
        if !dir.isEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: dir)) }
    }

    func revealPrefix(_ game: Game) {
        NSWorkspace.shared.open(URL(fileURLWithPath: paths.expand(game.prefix)))
    }

    func hasLogs(_ game: Game) -> Bool {
        FileManager.default.fileExists(atPath: paths.gameLogsDir(gameID: game.gameID) + "/wine.log")
    }

    // MARK: Runners

    func installedRunners() -> [InstalledRunner] { RunnerStore(paths: paths).installed() }
}
