import AppKit
import FaugusCore
import Foundation

/// `Faugus --game <id> [--logs]`: the per-game supervisor process (plan section 5). It is an
/// `.accessory` app so it has no Dock icon or menu bar, but can show the splash and dialogs.
@MainActor
final class RunnerMode {
    private let paths = FaugusPaths.live
    private let splash = SplashPanel()
    private var translator: Translator = .identity
    private var windowWatcherTask: Task<Void, Never>?
    private var gameID = ""
    private var prefix = ""
    private var isSteam = false
    private var splashShownAt = Date()

    static func run(
        gameID: String,
        logs: Bool,
        preLaunch: String,
        postLaunch: String,
        runFile: String? = nil,
        adhocGame: Game? = nil
    ) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let mode = RunnerMode()
        Task { @MainActor in
            await mode.start(
                gameID: gameID,
                logs: logs,
                preLaunch: preLaunch,
                postLaunch: postLaunch,
                runFile: runFile,
                adhocGame: adhocGame
            )
            exit(0)
        }
        app.run()
        exit(0)
    }

    /// `--run <file>` in a saved game's prefix, or in a prefix from the Add Game dialog.
    static func run(
        target: RunFileTarget,
        logs: Bool,
        preLaunch: String,
        postLaunch: String,
        runFile: String
    ) -> Never {
        switch target {
        case let .game(id):
            run(gameID: id, logs: logs, preLaunch: preLaunch, postLaunch: postLaunch, runFile: runFile)
        case let .prefix(path, runner, logID):
            var game = Game(gameID: logID.isEmpty ? "installer" : logID, title: logID.isEmpty ? "installer" : logID)
            game.prefix = path
            game.runner = runner
            run(
                gameID: game.gameID,
                logs: logs,
                preLaunch: preLaunch,
                postLaunch: postLaunch,
                runFile: runFile,
                adhocGame: game
            )
        }
    }

    // swiftlint:disable:next function_parameter_count
    private func start(
        gameID: String,
        logs: Bool,
        preLaunch: String,
        postLaunch: String,
        runFile: String?,
        adhocGame: Game?
    ) async {
        self.gameID = gameID
        let game = adhocGame ?? (try? GamesStore(paths: paths).loadAll())?.first { $0.gameID == gameID }
        prefix = paths.expand(game?.prefix ?? "")
        let config = try? FaugusConfig.load(paths: paths)
        let language =
            ProcessInfo.processInfo.environment["FAUGUS_LANG"]
                ?? config?.string("language", default: "en_US") ?? "en_US"
        translator = AppModel.languageCatalogs()?.translator(for: language) ?? .identity
        // Running a file in the prefix shows no splash (upstream), only errors.
        let splashEnabled = runFile == nil && (config?.bool("splash-window-enabled") ?? true)

        isSteam = game?.runner == "Steam"
        if splashEnabled {
            splash.model.title = game?.title ?? gameID
            splash.model.status = translator("Loading...")
            splash.show(
                iconPath: game?.icon,
                fallbackIconPath: Bundle.main.resourceURL?.appendingPathComponent("assets/faugus-launcher-raster.png")
                    .path
            )
            splashShownAt = Date()
            startWindowWatcher()
        }

        var options = SupervisorOptions()
        options.logs = logs
        options.runFile = runFile
        options.adhocGame = adhocGame
        if !preLaunch.isEmpty {
            options.preLaunch = preLaunch
        }
        if !postLaunch.isEmpty {
            options.postLaunch = postLaunch
        }
        options.allowDownloads = true
        options.ensureRosetta = { await RunnerMode.askToInstallRosetta() }
        options.discordIconProvider = { game in
            await RunnerMode.discordIconURL(for: game, configuration: config)
        }

        let supervisor = GameSupervisor(paths: paths, gameID: gameID, options: options) { event in
            Task { @MainActor in RunnerModeRelay.shared.mode?.handle(event) }
        }
        RunnerModeRelay.shared.mode = self

        let failure = await supervisor.run()
        windowWatcherTask?.cancel()
        splash.close()
        if let failure {
            showFailure(failure)
        }
        if runFile != nil {
            return
        }
        DistributedNotificationCenter.default().postNotificationName(
            .faugusRefreshMenu, object: nil, userInfo: nil, deliverImmediately: true
        )
    }

    // MARK: Events

    func handle(_ event: SupervisorEvent) {
        let translate = translator
        switch event {
        case .preparing: splash.model.status = translate("Loading...")
        case .checkingRosetta: break
        case let .downloadingRunner(name, progress), let .downloadingComponent(name, progress):
            splash.model.status = "Downloading \(name)..."
            splash.model.progress = progress
        case .creatingPrefix:
            splash.model.progress = nil
            splash.model.status = translate("Creating prefix...")
        case .starting, .running:
            splash.model.progress = nil
            splash.model.status = isSteam ? translate("Starting Steam game...") : translate("Starting game...")
        case .stopping, .exited, .failed: break
        }
    }

    /// Polls on the main actor with `Task.sleep` rather than `Timer.scheduledTimer`. A timer
    /// scheduled from the startup `Task` often never fires while `await supervisor.run()` holds
    /// the process, which left Battle.net on "Starting game..." until Stop.
    private func startWindowWatcher() {
        windowWatcherTask?.cancel()
        windowWatcherTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.splash.isVisible {
                let timedOut = Date().timeIntervalSince(self.splashShownAt) > 15
                if timedOut || GameWindowWatcher.gameWindowVisible(gameID: self.gameID, prefix: self.prefix) {
                    self.splash.close()
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    // MARK: Dialogs

    private nonisolated static func askToInstallRosetta() async -> Bool {
        let accepted: Bool = await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "Rosetta 2 is required"
            alert.informativeText =
                "Faugus runs Wine, which is built for Intel Macs, through Rosetta 2. Install it now? "
                    + "macOS will ask for your administrator password."
            alert.addButton(withTitle: "Install Rosetta")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            return alert.runModal() == .alertFirstButtonReturn
        }
        guard accepted else { return false }
        do { try await Rosetta.install() } catch { return false }
        return await Rosetta.isInstalled()
    }

    /// SteamGridDB icon URL for the generic Discord activity (`_discord_find_icon`).
    private static func discordIconURL(for game: Game, configuration: FaugusConfig?) async -> String? {
        guard let configuration, let client = SteamGridDBSettings(configuration: configuration).makeClient()
        else { return nil }
        let steamGridID = Int(game.steamGridDBID)
        let found = await client.candidates(gameName: game.title, limit: 1, gameID: steamGridID)
        guard let icon = found.icons.first else { return nil }
        return SteamGridDBClient.iconDownloadURL(for: icon)
    }

    private func showFailure(_ failure: SupervisorFailure) {
        let translate = translator
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch failure {
        case let .runnerNotFound(name):
            alert.messageText = translate.format("%s was not found", name)
            alert.informativeText = "Open the Runner Manager to install it, or choose another runner."
        case .rosettaMissing:
            alert.messageText = "Rosetta 2 is required"
            alert.informativeText = "Install it with: softwareupdate --install-rosetta"
        default:
            alert.messageText = failure.description
        }
        alert.addButton(withTitle: translate("Close"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

extension Notification.Name {
    /// `refresh-menu` from the plan's IPC table.
    static let faugusRefreshMenu = Notification.Name("me.tomijaroli.faugus-mac.refresh-menu")
}

@MainActor
final class RunnerModeRelay {
    static let shared = RunnerModeRelay()
    var mode: RunnerMode?
}
