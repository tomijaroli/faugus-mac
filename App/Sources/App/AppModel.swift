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
    var showSettings = false
    /// The unsaved Settings draft. Interface options preview live and revert on Cancel.
    var previewConfig: FaugusConfig? {
        didSet {
            applyAppearance()
            // `show-hidden` changes the games list, everything else is read live.
            let old = (oldValue ?? config)?.bool("show-hidden")
            let new = (previewConfig ?? config)?.bool("show-hidden")
            if old != new { reloadGames() }
        }
    }
    private(set) var games: [Game] = []
    private(set) var translator: Translator = .identity
    private(set) var languageCode: String = "en_US"
    private(set) var loadError: String?
    /// `gameid -> runner pid`, refreshed once per second and on `refresh-menu`.
    private(set) var running: [String: Int32] = [:]
    var actionError: String?

    // Library state (search, sort, category, zoom and selection of the main window).
    var searchText = ""
    var sortMode: SortMode = .alpha { didSet { if sortMode != oldValue { persistInterfaceState() } } }
    var category: CategorySelection = .all { didSet { if category != oldValue { persistInterfaceState() } } }
    /// Cover zoom in percent, 50 to 100 in steps of 10.
    var coverSize = 100 { didSet { if coverSize != oldValue { persistInterfaceState() } } }
    var selection: String?
    var customOrder: [String: Int] = [:]
    var categoryNames: [String] = []
    @ObservationIgnored var dragSourceID: String?
    @ObservationIgnored var playSessions: [String: (start: Date?, baseline: Int)] = [:]
    @ObservationIgnored private var restoredInterfaceState = false

    /// What the library draws with: the Settings draft while the dialog is open.
    var activeConfig: FaugusConfig? { previewConfig ?? config }

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
            games = try GamesStore(paths: paths).load(showHidden: (previewConfig ?? cfg).bool("show-hidden"))
            running = RunningGames(paths: paths).load()
            customOrder = CustomOrderStore(paths: paths).load()
            categoryNames = CategoryStore(paths: paths).load()
            restoreInterfaceState(cfg)
            loadError = nil
            applyAppearance()
        } catch {
            loadError = "\(error)"
        }
    }

    private func reloadGames() {
        let show = activeConfig?.bool("show-hidden") ?? false
        if let loaded = try? GamesStore(paths: paths).load(showHidden: show) { games = loaded }
    }

    /// Applies `sort`, `category` and `cover-size` from `config.json` once per launch.
    private func restoreInterfaceState(_ cfg: FaugusConfig) {
        guard !restoredInterfaceState else { return }
        restoredInterfaceState = true
        sortMode = SortMode(configValue: cfg.string("sort", default: "alpha"))
        category = CategorySelection(configValue: cfg.string("category", default: "all"))
        let size = cfg.int("cover-size", default: 100)
        coverSize = min(100, max(50, size))
    }

    /// Edits and saves `config.json` (used for interface state saved outside Settings).
    func updateConfig(_ body: (inout FaugusConfig) -> Void) {
        guard var cfg = config else { return }
        body(&cfg)
        guard cfg != config else { return }
        do { try cfg.save() } catch { actionError = "\(error)"; return }
        config = cfg
    }

    private func persistInterfaceState() {
        guard restoredInterfaceState else { return }
        updateConfig {
            $0.setValue("sort", sortMode.rawValue)
            $0.setValue("category", category.configValue)
            $0.setValue("cover-size", String(coverSize))
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

    // MARK: Settings

    /// `interface-theme` (system/light/dark) drives the app appearance; `accent-mode`
    /// `custom` supplies a tint.
    func applyAppearance() {
        guard let cfg = activeConfig else { return }
        switch cfg.string("interface-theme", default: "system") {
        case "light": NSApp?.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp?.appearance = NSAppearance(named: .darkAqua)
        default: NSApp?.appearance = nil
        }
    }

    /// The custom accent colour, or `nil` for the system one.
    var accentColor: ConfigColor? {
        guard let cfg = activeConfig, cfg.accentColor() != "system" else { return nil }
        return ConfigColor(cfg.accentColor())
    }

    /// Settings "Ok": writes `config.json` and `envar.json`.
    func saveSettings(_ cfg: FaugusConfig, envars: [String]) {
        do {
            try cfg.save()
            try EnvarStore(paths: paths).save(envars)
            actionError = nil
        } catch {
            actionError = "\(error)"
        }
        previewConfig = nil
        reload()
    }

    func discardSettingsPreview() { previewConfig = nil }

    func logsSize() -> Int64? { LogsMaintenance.size(of: paths.logsDir) }

    func clearLogs() {
        do { try LogsMaintenance.clear(paths: paths) } catch { actionError = "\(error)" }
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
        try? CustomOrderStore(paths: paths).remove(gameID: game.gameID)
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
