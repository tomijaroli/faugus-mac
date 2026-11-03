import AppKit
import FaugusCore
import ServiceManagement

/// Owns what lives outside the SwiftUI scene: the menu bar item, "close hides to the tray",
/// the single-instance notifications (`open`, `quit`) and the login item.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) static var shared: AppDelegate?

    /// Set by `FaugusLauncherApp.init`, before the delegate or any window exists.
    static var sharedModel: AppModel?

    var model: AppModel? {
        Self.sharedModel
    }

    /// `--hide` on the command line.
    private var startHidden: Bool {
        if case let .launcher(hidden, _, _) = LaunchMode.parse(Array(CommandLine.arguments.dropFirst())) {
            return hidden
        }
        return false
    }

    private let tray = TrayController()
    private var mainWindow: NSWindow?
    private var windowDelegate: HideOnCloseWindowDelegate?
    private var notificationTokens: [NSObjectProtocol] = []
    private var didApplyStartupVisibility = false

    /// `system-tray`: closing the window keeps the app alive in the menu bar.
    var isTrayEnabled: Bool {
        model?.config?.bool("system-tray") ?? false
    }

    // MARK: NSApplicationDelegate

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        configureTray()
        applyTraySettings()
        observeOtherInstances()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        !isTrayEnabled
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows hasVisibleWindow: Bool) -> Bool {
        if !hasVisibleWindow {
            presentLauncher()
        }
        return true
    }

    // MARK: Tray

    private func configureTray() {
        tray.menuContent = { [weak self] in
            guard let self, let model else { return ([], .identity) }
            // Hidden games count too: upstream's tray reads games.json directly.
            let games = (try? GamesStore(paths: model.paths).load(showHidden: true)) ?? model.games
            return (games, model.translator)
        }
        tray.isGameRunning = { [weak self] gameID in
            self?.model?.running[gameID] != nil
        }
        tray.launchGame = { [weak self] gameID in
            guard let model = self?.model else { return }
            let allGames = (try? GamesStore(paths: model.paths).load(showHidden: true)) ?? model.games
            guard let game = allGames.first(where: { $0.gameID == gameID }) else { return }
            model.play(game, withLogs: false)
        }
        tray.openLauncher = { [weak self] in self?.presentLauncher() }
        tray.quitLauncher = { NSApp.terminate(nil) }
    }

    /// Applies `system-tray`, `mono-icon` and the login item from the saved configuration. Called at launch
    /// and after Settings is saved.
    func applyTraySettings() {
        guard let configuration = model?.config else { return }
        tray.apply(enabled: configuration.bool("system-tray"), monochrome: configuration.bool("mono-icon"))
        applyLoginItem(enabled: configuration.bool("autostart-enabled"))
        if !configuration.bool("system-tray"), mainWindow?.isVisible == false {
            // The tray was switched off while the window was hidden: nothing could show it again.
            presentLauncher()
        }
    }

    /// Upstream writes `~/.config/autostart/faugus-launcher.desktop`; macOS registers the app as a login item.
    /// "Minimized startup" needs no argument: like upstream's tray entry point, the launcher reads
    /// `minimized-startup-enabled` on every start.
    private func applyLoginItem(enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled, service.status != .enabled {
                try service.register()
            } else if !enabled, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            model?.actionError = "\(error.localizedDescription)"
        }
    }

    // MARK: Window

    /// Called by the window configurator for the main window.
    func adopt(_ window: NSWindow) {
        guard mainWindow !== window else { return }
        mainWindow = window
        let proxy = HideOnCloseWindowDelegate(original: window.delegate) { [weak self] in
            self?.isTrayEnabled ?? false
        } didHide: {
            // No Dock icon while only the menu bar item is left, like upstream's tray-only process.
            NSApp.setActivationPolicy(.accessory)
        }
        windowDelegate = proxy
        window.delegate = proxy
        applyStartupVisibility(of: window)
    }

    /// `--hide`, or `minimized-startup-enabled` with the tray on, starts without the window.
    private func applyStartupVisibility(of window: NSWindow) {
        guard !didApplyStartupVisibility else { return }
        didApplyStartupVisibility = true
        guard isTrayEnabled, startHidden || (model?.config?.bool("minimized-startup-enabled") ?? false) else { return }
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    func presentLauncher() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let mainWindow {
            if mainWindow.isMiniaturized {
                mainWindow.deminiaturize(nil)
            }
            mainWindow.makeKeyAndOrderFront(nil)
        }
    }

    /// "Auto-close": upstream's launcher exits once a game starts. With the tray on only the window goes away.
    func closeAfterLaunch() {
        if isTrayEnabled, let mainWindow {
            mainWindow.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.terminate(nil)
        }
    }

    // MARK: Other instances

    /// Finder Services: "Create Faugus Shortcut" on a selected file (`NSServices` in Info.plist).
    @objc func createFaugusShortcut(
        _ pasteboard: NSPasteboard, userData _: String, error _: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        guard let path = urls?.first?.path else { return }
        Task { @MainActor in
            model?.pendingShortcutFile = path
            presentLauncher()
        }
    }

    /// A second launch posts `open`; the plan's other IPC verbs (`quit`, `refresh-menu`) are handled here too.
    private func observeOtherInstances() {
        let center = DistributedNotificationCenter.default()
        notificationTokens
            .append(center.addObserver(forName: .faugusOpen, object: nil, queue: .main) { [weak self] notification in
                let shortcut = notification.userInfo?["shortcut"] as? String
                MainActor.assumeIsolated {
                    if let shortcut {
                        self?.model?.pendingShortcutFile = shortcut
                    }
                    self?.presentLauncher()
                }
            })
        notificationTokens.append(center.addObserver(forName: .faugusQuit, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        })
    }
}

/// Wraps the window's own delegate (SwiftUI installs one) so that closing hides the window while the tray is on.
@MainActor
final class HideOnCloseWindowDelegate: NSObject, NSWindowDelegate {
    private weak var original: NSWindowDelegate?
    private let shouldHide: () -> Bool
    private let didHide: () -> Void

    init(original: NSWindowDelegate?, shouldHide: @escaping () -> Bool, didHide: @escaping () -> Void) {
        self.original = original
        self.shouldHide = shouldHide
        self.didHide = didHide
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if shouldHide() {
            sender.orderOut(nil)
            didHide()
            return false
        }
        return original?.windowShouldClose?(sender) ?? true
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if let original, original.responds(to: selector) {
            return original
        }
        return super.forwardingTarget(for: selector)
    }
}

extension Notification.Name {
    /// `open` from the plan's IPC table: present the launcher window.
    static let faugusOpen = Notification.Name("me.tomijaroli.faugus-mac.open")
    /// `quit` from the plan's IPC table.
    static let faugusQuit = Notification.Name("me.tomijaroli.faugus-mac.quit")
}
