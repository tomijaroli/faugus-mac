import AppKit
import FaugusCore
import Foundation
import Observation

/// Shared state for the launcher UI: paths, config, translations and the games list.
@MainActor
@Observable
final class AppModel { // swiftlint:disable:this type_body_length
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
            if old != new {
                reloadGames()
            }
        }
    }

    private(set) var games: [Game] = []
    private(set) var translator: Translator = .identity
    private(set) var languageCode = "en_US"
    private(set) var loadError: String?
    /// `gameid -> runner pid`, refreshed once per second and on `refresh-menu`.
    private(set) var running: [String: Int32] = [:]
    /// `winetricks list-all`, kept for the session: it takes a few seconds to produce.
    var winetricksCatalog: [WinetricksCategory]?
    var actionError: String?
    /// `--shortcut <file>` or the Finder service, shown as a sheet on the running launcher.
    var pendingShortcutFile: String?
    /// Gamepad Y / Menu overlays (power menu and the gamepad-friendly context list).
    var showGamepadOverlay = false
    var gamepadOverlayTitle = "Faugus"
    var gamepadOverlayIndex = 0
    var gamepadOverlayConfirm = false
    var wantsNewGame = false
    /// Settings General / Interface, cycled with LB / RB.
    var settingsTab = 0
    /// `"%s is running"` from gamepad confirm on a running game.
    var runningGameWarning: String?
    var gamepadColumnCount = 1
    var gamepadGridIsHorizontal = false
    @ObservationIgnored var gamepadOverlayItems: [GamepadOverlayItem] = []
    @ObservationIgnored var libraryActions: GameActions?
    @ObservationIgnored private var gamepadMonitor: GamepadMonitor?

    // Library state (search, sort, category, zoom and selection of the main window).
    var searchText = ""
    var sortMode: SortMode = .alpha {
        didSet {
            if sortMode != oldValue {
                persistInterfaceState()
            }
        }
    }

    var category: CategorySelection = .all {
        didSet {
            if category != oldValue {
                persistInterfaceState()
            }
        }
    }

    /// Cover zoom in percent, 50 to 100 in steps of 10.
    var coverSize = 100 {
        didSet {
            if coverSize != oldValue {
                persistInterfaceState()
            }
        }
    }

    var selection: String?
    var customOrder: [String: Int] = [:]
    var categoryNames: [String] = []
    @ObservationIgnored var dragSourceID: String?
    @ObservationIgnored var playSessions: [String: (start: Date?, baseline: Int)] = [:]
    @ObservationIgnored private var restoredInterfaceState = false
    @ObservationIgnored private var steamInstalledCache: [String: (at: Date, ids: Set<String>, names: Set<String>)] =
        [:]
    @ObservationIgnored private var steamPlaytimeCache: [String: (at: Date, seconds: Int)] = [:]

    /// What the library draws with: the Settings draft while the dialog is open.
    var activeConfig: FaugusConfig? {
        previewConfig ?? config
    }

    var isRightToLeft: Bool {
        LanguageCatalogs.isRightToLeft(languageCode)
    }

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var notificationToken: NSObjectProtocol?

    init(paths: FaugusPaths = .live) {
        self.paths = paths
        reload()
        startPolling()
        SoundPlayer.shared.model = self
        gamepadMonitor = GamepadMonitor(model: self)
    }

    // MARK: Loading

    func reload() {
        do {
            try paths.ensureDirectories()
            let configuration = try FaugusConfig.load(paths: paths)
            config = configuration
            // `FAUGUS_LANG` is a QA override that never touches config.json.
            languageCode = ProcessInfo.processInfo.environment["FAUGUS_LANG"] ?? configuration.string(
                "language",
                default: "en_US"
            )
            translator = Self.languageCatalogs()?.translator(for: languageCode) ?? .identity
            games = try GamesStore(paths: paths).load(showHidden: (previewConfig ?? configuration).bool("show-hidden"))
            running = RunningGames(paths: paths).load()
            customOrder = CustomOrderStore(paths: paths).load()
            categoryNames = CategoryStore(paths: paths).load()
            restoreInterfaceState(configuration)
            loadError = nil
            applyAppearance()
        } catch {
            loadError = "\(error)"
        }
    }

    private func reloadGames() {
        let show = activeConfig?.bool("show-hidden") ?? false
        if let loaded = try? GamesStore(paths: paths).load(showHidden: show) {
            games = loaded
        }
    }

    /// Applies `sort`, `category` and `cover-size` from `config.json` once per launch.
    private func restoreInterfaceState(_ configuration: FaugusConfig) {
        guard !restoredInterfaceState else { return }
        restoredInterfaceState = true
        sortMode = SortMode(configValue: configuration.string("sort", default: "alpha"))
        category = CategorySelection(configValue: configuration.string("category", default: "all"))
        let size = configuration.int("cover-size", default: 100)
        coverSize = min(100, max(50, size))
    }

    /// Edits and saves `config.json` (used for interface state saved outside Settings).
    func updateConfig(_ body: (inout FaugusConfig) -> Void) {
        guard var configuration = config else { return }
        body(&configuration)
        guard configuration != config else { return }
        do { try configuration.save() } catch { actionError = "\(error)"
            return
        }
        config = configuration
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
                let paths = paths
                let previous = running
                let current = await Task.detached { () -> [String: Int32] in
                    let store = RunningGames(paths: paths)
                    _ = store.pruneDead()
                    return store.load()
                }.value
                if current != previous {
                    running = current
                    // A game ended: playtime and last_played changed on disk.
                    if current.count < previous.count || Set(previous.keys) != Set(current.keys) {
                        reload()
                    }
                }
            }
        }
    }

    /// `Contents/Resources/languages`, or `FAUGUS_LANGUAGES_DIR` when running unbundled.
    static func languageCatalogs() -> LanguageCatalogs? {
        if let override = ProcessInfo.processInfo.environment["FAUGUS_LANGUAGES_DIR"] {
            return LanguageCatalogs(localeDirectory: URL(fileURLWithPath: override))
        }
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("languages"),
              FileManager.default.fileExists(atPath: directory.path)
        else { return nil }
        return LanguageCatalogs(localeDirectory: directory)
    }

    // MARK: Settings

    /// `interface-theme` (system/light/dark) drives the app appearance; `accent-mode`
    /// `custom` supplies a tint.
    func applyAppearance() {
        guard let configuration = activeConfig else { return }
        switch configuration.string("interface-theme", default: "system") {
        case "light": NSApp?.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp?.appearance = NSAppearance(named: .darkAqua)
        default: NSApp?.appearance = nil
        }
    }

    /// The custom accent colour, or `nil` for the system one.
    var accentColor: ConfigColor? {
        guard let configuration = activeConfig, configuration.accentColor() != "system" else { return nil }
        return ConfigColor(configuration.accentColor())
    }

    /// Settings "Ok": writes `config.json` and `envar.json`.
    func saveSettings(_ configuration: FaugusConfig, environmentVariables: [String]) {
        do {
            try configuration.save()
            try EnvironmentVariableStore(paths: paths).save(environmentVariables)
            actionError = nil
        } catch {
            actionError = "\(error)"
        }
        previewConfig = nil
        reload()
        AppDelegate.shared?.applyTraySettings()
    }

    func discardSettingsPreview() {
        previewConfig = nil
    }

    func logsSize() -> Int64? {
        LogsMaintenance.size(of: paths.logsDirectory)
    }

    func clearLogs() {
        do { try LogsMaintenance.clear(paths: paths) } catch { actionError = "\(error)" }
    }

    // MARK: Running games

    func isRunning(_ game: Game) -> Bool {
        running[game.gameID] != nil
    }

    func canPlay(_ game: Game) -> Bool {
        isRunning(game) || !game.needsAttention
    }

    /// Spawns `Faugus --game <id> [--logs]` in its own session, so quitting the launcher never
    /// stops a game (upstream behaviour; plan section 5).
    func play(_ game: Game, withLogs: Bool) {
        if isRunning(game) {
            stop(game)
            return
        }
        guard canPlay(game) else { return }
        guard let executablePath = Bundle.main.executablePath ?? CommandLine.arguments.first else { return }
        var arguments = [executablePath, "--game", game.gameID]
        if withLogs {
            arguments.append("--logs")
        }
        let gameDirectory = (paths.expand(game.path) as NSString).deletingLastPathComponent
        var isDirectory: ObjCBool = false
        let workingDirectory = FileManager.default
            .fileExists(atPath: gameDirectory, isDirectory: &isDirectory) && isDirectory
            .boolValue ? gameDirectory : nil
        do {
            _ = try ProcessSpawner.spawn(
                commandLine: arguments,
                options: .init(
                    workingDirectory: workingDirectory,
                    environment: ProcessInfo.processInfo.environment,
                    newSession: true
                )
            )
            actionError = nil
            updateLastPlayedOrdering(game)
            if config?.bool("auto-close-on-launch") == true {
                AppDelegate.shared?.closeAfterLaunch()
            }
        } catch {
            actionError = "\(error)"
        }
    }

    // MARK: Run a file in the prefix

    func recentRunFiles(for game: Game) -> [String] {
        RecentRunFiles(paths: paths).files(gameID: game.gameID)
    }

    func clearRecentRunFiles(for game: Game) {
        try? RecentRunFiles(paths: paths).clear(gameID: game.gameID)
    }

    /// Spawns `Faugus --run <file> --in-game <id>` (upstream `run_file_in_prefix`).
    func runFile(_ file: String, in game: Game, withLogs: Bool = false) {
        guard let executablePath = Bundle.main.executablePath ?? CommandLine.arguments.first else { return }
        var arguments = [executablePath, "--run", file, "--in-game", game.gameID]
        if withLogs {
            arguments.append("--logs")
        }
        do {
            var environment = ProcessInfo.processInfo.environment
            environment["FAUGUS_DISABLE_UPDATES"] = "1"
            _ = try ProcessSpawner.spawn(
                commandLine: arguments,
                options: .init(workingDirectory: nil, environment: environment, newSession: true)
            )
            try? RecentRunFiles(paths: paths).record(gameID: game.gameID, file: file)
            actionError = nil
        } catch {
            actionError = "\(error)"
        }
    }

    /// The Add Game dialog's "Run" and "Run an installer": runs `file` in a prefix that may not
    /// belong to a saved game yet, and returns once it has exited.
    func runInPrefix(file: String, prefix: String, runner: String, logID: String) async -> Bool {
        guard let executablePath = Bundle.main.executablePath ?? CommandLine.arguments.first else { return false }
        let arguments = [executablePath, "--run", file, "--in-prefix", prefix, "--runner", runner, "--log-id", logID]
        do {
            let pid = try ProcessSpawner.spawn(
                commandLine: arguments,
                options: .init(
                    workingDirectory: nil,
                    environment: ProcessInfo.processInfo.environment,
                    newSession: true
                )
            )
            actionError = nil
            await Task.detached {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            }.value
            return true
        } catch {
            actionError = "\(error)"
            return false
        }
    }

    /// The default prefix (`<default-prefix>/default`) that Settings' Winecfg, Winetricks and
    /// Run work in, with the default runner.
    var defaultPrefixPath: String {
        let base = paths.expand(config?.string("default-prefix") ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return (base.isEmpty ? paths.prefixesDirectory : base) + "/default"
    }

    func runInDefaultPrefix(file: String) async -> Bool {
        await runInPrefix(file: file, prefix: defaultPrefixPath, runner: "Default", logID: "default")
    }

    func stop(_ game: Game) {
        try? RunningGames(paths: paths).requestStop(gameID: game.gameID)
    }

    private func updateLastPlayedOrdering(_: Game) {
        // Upstream records `latest-games.json`; that arrives with the full library (P2).
    }

    // MARK: Editing

    func existingIDs() -> Set<String> {
        (try? GamesStore(paths: paths).existingGameIDs()) ?? []
    }

    /// Adds or replaces a game (matched on `gameid`) and writes games.json.
    func save(_ game: Game) {
        var saved = game
        saved.needsAttention = false
        var all = (try? GamesStore(paths: paths).loadAll()) ?? []
        if let index = all.firstIndex(where: { $0.gameID == saved.gameID }) {
            all[index] = saved
        } else {
            all.append(saved)
        }
        write(all, deleted: nil)
    }

    /// `_on_confirm_delete_response`: stops the game if it runs, removes its artwork and add-app
    /// bat, drops it from the custom order and writes games.json. With `removePrefix` the prefix
    /// goes to the Trash (never `rm`), and only when no other game still uses it.
    func delete(_ game: Game, removePrefix: Bool) {
        if isRunning(game) {
            stop(game)
        }
        let all = ((try? GamesStore(paths: paths).loadAll()) ?? []).filter { $0.gameID != game.gameID }
        let prefix = paths.expand(game.prefix)
        let shared = all.contains { paths.expand($0.prefix) == prefix }
        GameEditing.removeOwnedFiles(of: game, paths: paths)
        removeShortcuts(ofGameID: game.gameID)
        write(all, deleted: game.gameID)
        try? CustomOrderStore(paths: paths).remove(gameID: game.gameID)
        guard removePrefix, !shared, !prefix.isEmpty, FileManager.default.fileExists(atPath: prefix) else { return }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: prefix), resultingItemURL: nil)
        } catch {
            actionError = "\(translator("Failed to remove prefix")): \(error.localizedDescription)"
        }
    }

    /// Other games sharing this game's prefix (upstream warns before deleting).
    func gamesSharingPrefix(with game: Game) -> Int {
        GameEditing.otherGamesUsingPrefix(of: game, in: games, paths: paths)
    }

    /// Duplicates under a new title (`DuplicateDialog`). Returns the failure to show, if any.
    @discardableResult
    func duplicate(_ game: Game, as title: String) -> GameEditing.DuplicateError? {
        let all = (try? GamesStore(paths: paths).loadAll()) ?? games
        do {
            let copy = try GameEditing.duplicate(game, newTitle: title, existing: all, paths: paths)
            save(copy)
            selection = copy.gameID
            searchText = ""
            return nil
        } catch let duplicateError as GameEditing.DuplicateError {
            return duplicateError
        } catch {
            actionError = "\(error)"
            return nil
        }
    }

    func toggleHidden(_ game: Game) {
        var toggledGame = game
        toggledGame.hidden.toggle()
        save(toggledGame)
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

    func gameLocation(_ game: Game) -> String? {
        if game.runner == "Steam" {
            return steam.installFolder(appID: game.path)
        }
        let directory = (paths.expand(game.path) as NSString).deletingLastPathComponent
        return directory.isEmpty ? nil : directory
    }

    /// Steam-type games have no prefix here (macOS Steam keeps no Proton prefixes).
    func prefixLocation(_ game: Game) -> String? {
        guard game.runner != "Steam" else { return nil }
        let prefix = paths.expand(game.prefix)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: prefix, isDirectory: &isDirectory) && isDirectory
            .boolValue ? prefix : nil
    }

    func revealGameLocation(_ game: Game) {
        if let directory = gameLocation(game) {
            NSWorkspace.shared.open(URL(fileURLWithPath: directory))
        }
    }

    func revealPrefix(_ game: Game) {
        if let directory = prefixLocation(game) {
            NSWorkspace.shared.open(URL(fileURLWithPath: directory))
        }
    }

    // MARK: Steam

    var steam: SteamLibrary {
        SteamLibrary(home: paths.home)
    }

    /// Upstream's `is_game_installed`: the executable exists, or for Steam the app id (or the
    /// title) is among Steam's installed games. Steam is re-read at most every 3 seconds.
    func isInstalled(_ game: Game) -> Bool {
        guard game.runner == "Steam" else { return FileManager.default.fileExists(atPath: paths.expand(game.path)) }
        let user = game.steamUser.isEmpty ? "all" : game.steamUser
        let now = Date()
        var entry = steamInstalledCache[user]
        if entry == nil || now.timeIntervalSince(entry!.at) > 3 {
            let installed = steam.installedGames(accountID: user)
            entry = (now, Set(installed.map(\.appID)), Set(installed.map { $0.name.lowercased() }))
            steamInstalledCache[user] = entry
        }
        return entry!.ids.contains(game.path) || entry!.names.contains(game.title.lowercased())
    }

    /// Seconds played: Faugus's own count, or Steam's for Steam-type games.
    func playtimeSeconds(_ game: Game) -> Int {
        guard game.runner == "Steam" else { return game.playtime }
        let key = game.path + "|" + game.steamUser
        let now = Date()
        if let cachedPlaytime = steamPlaytimeCache[key], now.timeIntervalSince(cachedPlaytime.at) <= 5 {
            return cachedPlaytime.seconds
        }
        let seconds = steam
            .playtimeMinutes(appID: game.path, accountID: game.steamUser.isEmpty ? nil : game.steamUser) * 60
        steamPlaytimeCache[key] = (now, seconds)
        return seconds
    }

    func hasLogs(_ game: Game) -> Bool {
        FileManager.default.fileExists(atPath: paths.gameLogsDirectory(gameID: game.gameID) + "/wine.log")
    }

    // MARK: Runners

    func installedRunners() -> [InstalledRunner] {
        RunnerStore(paths: paths).installed()
    }
}
