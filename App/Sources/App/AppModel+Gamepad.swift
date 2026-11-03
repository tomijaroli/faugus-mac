import AppKit
import FaugusCore
import Foundation

struct GamepadOverlayItem {
    var title: String
    var isEnabled: Bool
    var action: () -> Void
}

extension AppModel {
    var isConsoleMode: Bool {
        if case let .launcher(_, console, _) = LaunchMode.parse(Array(CommandLine.arguments.dropFirst())) {
            return console
        }
        return false
    }

    var isGamepadEnabled: Bool {
        ConsoleMode.gamepadEnabled(
            isConsole: isConsoleMode,
            stored: activeConfig?.bool("gamepad-navigation") ?? false
        )
    }

    var isGamepadUsable: Bool {
        isGamepadEnabled && running.isEmpty && NSApp.isActive
    }

    func playSound(_ kind: UISoundKind) {
        SoundPlayer.shared.play(kind)
    }

    /// A / Cross: play the selected game, or activate the overlay row.
    func handleGamepadConfirm() {
        if showGamepadOverlay {
            gamepadOverlayConfirm = true
            return
        }
        if hasBlockingSheet {
            return
        }
        guard let game = selectedGame else { return }
        playOrNotify(game)
    }

    /// B / Circle: close overlay or the front sheet.
    func handleGamepadBack() {
        if showGamepadOverlay {
            dismissGamepadOverlay()
            playSound(.cancel)
            return
        }
        if hasBlockingSheet {
            sendKeyToKeyWindow(keyCode: 53, characters: "\u{1b}")
            playSound(.cancel)
        }
    }

    /// X / Square: kill all running games (ignored while a dialog is up).
    func handleGamepadKill() {
        guard !showGamepadOverlay, !hasBlockingSheet else { return }
        killAll()
        playSound(.cancel)
    }

    /// Y / Triangle: gamepad context menu for the selected game.
    func handleGamepadMenu() {
        guard !showGamepadOverlay, !hasBlockingSheet, let game = selectedGame else { return }
        openGamepadContext(for: game)
    }

    /// LB / L1: Add Game, or previous Settings tab.
    func handleGamepadAdd() {
        if showSettings {
            settingsTab = settingsTab == 0 ? 1 : 0
            playSound(.navigate)
            return
        }
        guard !showGamepadOverlay, !hasBlockingSheet else { return }
        wantsNewGame = true
        playSound(.confirm)
    }

    /// RB / R1: Settings, or next Settings tab.
    func handleGamepadSettings() {
        if showSettings {
            settingsTab = settingsTab == 0 ? 1 : 0
            playSound(.navigate)
            return
        }
        guard !showGamepadOverlay, !hasBlockingSheet else { return }
        showSettings = true
        playSound(.confirm)
    }

    /// Menu / Options: power menu.
    func handleGamepadPower() {
        guard !showGamepadOverlay, !hasBlockingSheet else { return }
        openPowerMenu()
    }

    func handleGamepadDirection(_ direction: GamepadDirection) {
        if showGamepadOverlay {
            let delta = (direction == .upward || direction == .left) ? -1 : 1
            let count = gamepadOverlayItems.count
            guard count > 0 else { return }
            gamepadOverlayIndex = (gamepadOverlayIndex + delta + count) % count
            playSound(.navigate)
            return
        }
        guard !hasBlockingSheet else { return }
        moveLibrarySelection(direction)
    }

    func handleGamepadScroll(deltaX: Double, deltaY: Double) {
        guard isGamepadUsable, !showGamepadOverlay else { return }
        guard abs(deltaX) > 0.5 || abs(deltaY) > 0.5 else { return }
        guard let window = NSApp.keyWindow, let content = window.contentView,
              let scrollView = Self.findScrollView(in: content)
        else { return }
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.x += deltaX
        origin.y += deltaY
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    func playOrNotify(_ game: Game) {
        if isRunning(game) {
            runningGameWarning = game.title
            playSound(.warning)
            return
        }
        playSound(.confirm)
        play(game, withLogs: false)
    }

    func openPowerMenu() {
        let translate = translator
        gamepadOverlayTitle = "Faugus"
        gamepadOverlayIndex = 0
        gamepadOverlayConfirm = false
        gamepadOverlayItems = [
            GamepadOverlayItem(title: translate("Shut down"), isEnabled: true, action: { PowerAction.shutDown() }),
            GamepadOverlayItem(title: translate("Reboot"), isEnabled: true, action: { PowerAction.reboot() }),
            GamepadOverlayItem(title: translate("Close"), isEnabled: true, action: { PowerAction.closeLauncher() }),
        ]
        showGamepadOverlay = true
        playSound(.navigate)
    }

    func openGamepadContext(for game: Game) {
        let translate = translator
        let running = isRunning(game)
        let supportsLogs = game.runner != "Steam" && game.runner != "Linux-Native"
        var items: [GamepadOverlayItem] = []
        items.append(GamepadOverlayItem(
            title: running ? translate("Stop") : supportsLogs ? translate("Play with logs") : translate("Play"),
            isEnabled: true,
            action: { [weak self] in
                guard let self else { return }
                if running {
                    stop(game)
                } else {
                    play(game, withLogs: supportsLogs)
                }
            }
        ))
        items.append(GamepadOverlayItem(title: translate("Edit"), isEnabled: true, action: { [weak self] in
            self?.libraryActions?.edit(game)
        }))
        items.append(GamepadOverlayItem(title: translate("Delete"), isEnabled: true, action: { [weak self] in
            self?.libraryActions?.delete(game)
        }))
        if game.runner != "Steam" {
            items.append(GamepadOverlayItem(title: translate("Duplicate"), isEnabled: true, action: { [weak self] in
                self?.libraryActions?.duplicate(game)
            }))
        }
        items.append(GamepadOverlayItem(
            title: game.hidden ? translate("Remove from hidden") : translate("Hide"),
            isEnabled: true,
            action: { [weak self] in self?.toggleHidden(game) }
        ))
        items.append(GamepadOverlayItem(
            title: translate("Open game location"),
            isEnabled: gameLocation(game) != nil,
            action: { [weak self] in self?.revealGameLocation(game) }
        ))
        if game.runner != "Linux-Native" {
            items.append(GamepadOverlayItem(
                title: translate("Open prefix location"),
                isEnabled: prefixLocation(game) != nil,
                action: { [weak self] in self?.revealPrefix(game) }
            ))
        }
        if supportsLogs {
            items.append(GamepadOverlayItem(
                title: translate("Show logs"),
                isEnabled: hasLogs(game),
                action: { [weak self] in
                    guard let self else { return }
                    LogsWindowController.show(game: game, model: self)
                }
            ))
        }
        if game.runner != "Steam", game.runner != "Linux-Native" {
            items.append(GamepadOverlayItem(
                title: translate("Run file in the prefix"),
                isEnabled: true,
                action: { [weak self] in
                    guard let self else { return }
                    if let file = FilePicker.choose(message: translate("Select a file to run in the prefix")) {
                        runFile(file, in: game)
                    }
                }
            ))
        }
        gamepadOverlayTitle = game.title
        gamepadOverlayIndex = 0
        gamepadOverlayConfirm = false
        gamepadOverlayItems = items
        showGamepadOverlay = true
        playSound(.navigate)
    }

    func dismissGamepadOverlay() {
        showGamepadOverlay = false
        gamepadOverlayConfirm = false
        gamepadOverlayItems = []
    }

    private func moveLibrarySelection(_ direction: GamepadDirection) {
        let games = visibleGames
        guard let current = games.firstIndex(where: { $0.gameID == selection }) else {
            selection = games.first?.gameID
            return
        }
        let wraps = interfaceMode == .carrousel
        let mapped = mappedGridDirection(direction)
        if interfaceMode == .carrousel, mapped.isVertical {
            return
        }
        guard let next = GamepadLibraryNavigation.nextIndex(
            current: current,
            count: games.count,
            direction: mapped,
            columns: gamepadColumnCount,
            wraps: wraps
        ) else { return }
        selection = games[next].gameID
        playSound(.navigate)
    }

    /// Horizontal Grid/Covers: left/right move by a lane, up/down move by one.
    private func mappedGridDirection(_ direction: GamepadDirection) -> GamepadDirection {
        guard gamepadGridIsHorizontal else { return direction }
        return switch direction {
        case .left: .upward
        case .right: .downward
        case .upward: .left
        case .downward: .right
        }
    }

    private var hasBlockingSheet: Bool {
        showSettings || pendingShortcutFile != nil || runningGameWarning != nil
    }

    private func sendKeyToKeyWindow(keyCode: UInt16, characters: String) {
        guard let window = NSApp.keyWindow,
              let event = NSEvent.keyEvent(
                  with: .keyDown,
                  location: .zero,
                  modifierFlags: [],
                  timestamp: ProcessInfo.processInfo.systemUptime,
                  windowNumber: window.windowNumber,
                  context: nil,
                  characters: characters,
                  charactersIgnoringModifiers: characters,
                  isARepeat: false,
                  keyCode: keyCode
              )
        else { return }
        window.keyDown(with: event)
    }

    private static func findScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }
        for child in view.subviews {
            if let found = findScrollView(in: child) {
                return found
            }
        }
        return nil
    }
}
