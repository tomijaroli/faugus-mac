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
    private var windowTimer: Timer?
    private var gameID = ""
    private var splashShownAt = Date()

    static func run(gameID: String, logs: Bool, preLaunch: String, postLaunch: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let mode = RunnerMode()
        Task { @MainActor in
            await mode.start(gameID: gameID, logs: logs, preLaunch: preLaunch, postLaunch: postLaunch)
            exit(0)
        }
        app.run()
        exit(0)
    }

    private func start(gameID: String, logs: Bool, preLaunch: String, postLaunch: String) async {
        self.gameID = gameID
        let config = try? FaugusConfig.load(paths: paths)
        let language =
            ProcessInfo.processInfo.environment["FAUGUS_LANG"]
            ?? config?.string("language", default: "en_US") ?? "en_US"
        translator = AppModel.languageCatalogs()?.translator(for: language) ?? .identity
        let splashEnabled = config?.bool("splash-window-enabled") ?? true

        let game = (try? GamesStore(paths: paths).loadAll())?.first { $0.gameID == gameID }
        if splashEnabled {
            splash.model.title = game?.title ?? gameID
            splash.model.status = translator("Loading...")
            splash.show(
                iconPath: game?.icon,
                fallbackIconPath: Bundle.main.resourceURL?.appendingPathComponent("assets/faugus-launcher.png").path)
            splashShownAt = Date()
            startWindowWatcher()
        }

        var options = SupervisorOptions()
        options.logs = logs
        if !preLaunch.isEmpty { options.preLaunch = preLaunch }
        if !postLaunch.isEmpty { options.postLaunch = postLaunch }
        options.allowDownloads = true
        options.ensureRosetta = { await RunnerMode.askToInstallRosetta() }

        let supervisor = GameSupervisor(paths: paths, gameID: gameID, options: options) { event in
            Task { @MainActor in RunnerModeRelay.shared.mode?.handle(event) }
        }
        RunnerModeRelay.shared.mode = self

        let failure = await supervisor.run()
        windowTimer?.invalidate()
        splash.close()
        if let failure { showFailure(failure) }
        DistributedNotificationCenter.default().postNotificationName(
            .faugusRefreshMenu, object: nil, userInfo: nil, deliverImmediately: true)
    }

    // MARK: Events

    func handle(_ event: SupervisorEvent) {
        let t = translator
        switch event {
        case .preparing: splash.model.status = t("Loading...")
        case .checkingRosetta: break
        case .downloadingRunner(let name, let p), .downloadingComponent(let name, let p):
            splash.model.status = "Downloading \(name)..."
            splash.model.progress = p
        case .creatingPrefix:
            splash.model.progress = nil
            splash.model.status = t("Creating prefix...")
        case .starting, .running:
            splash.model.progress = nil
            splash.model.status = t("Starting game...")
        case .stopping, .exited, .failed: break
        }
    }

    private func startWindowWatcher() {
        windowTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.splash.isVisible else { return }
                let timedOut = Date().timeIntervalSince(self.splashShownAt) > 120
                if timedOut || GameWindowWatcher.gameWindowVisible(gameID: self.gameID) { self.splash.close() }
            }
        }
    }

    // MARK: Dialogs

    nonisolated private static func askToInstallRosetta() async -> Bool {
        let accepted: Bool = await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "Rosetta 2 is required"
            alert.informativeText =
                "Faugus runs Wine, which is built for Intel Macs, through Rosetta 2. Install it now? macOS will ask for your administrator password."
            alert.addButton(withTitle: "Install Rosetta")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            return alert.runModal() == .alertFirstButtonReturn
        }
        guard accepted else { return false }
        do { try await Rosetta.install() } catch { return false }
        return await Rosetta.isInstalled()
    }

    private func showFailure(_ failure: SupervisorFailure) {
        let t = translator
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch failure {
        case .runnerNotFound(let name):
            alert.messageText = t.format("%s was not found", name)
            alert.informativeText = "Open the Runner Manager to install it, or choose another runner."
        case .rosettaMissing:
            alert.messageText = "Rosetta 2 is required"
            alert.informativeText = "Install it with: softwareupdate --install-rosetta"
        default:
            alert.messageText = failure.description
        }
        alert.addButton(withTitle: t("Close"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

extension Notification.Name {
    /// `refresh-menu` from the plan's IPC table.
    static let faugusRefreshMenu = Notification.Name("me.tomijaroli.FaugusForMac.refresh-menu")
}

@MainActor
final class RunnerModeRelay {
    static let shared = RunnerModeRelay()
    var mode: RunnerMode?
}
