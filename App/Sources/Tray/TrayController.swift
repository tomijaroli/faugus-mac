import AppKit
import FaugusCore

/// The menu bar item that replaces upstream's StatusNotifierItem tray (`tray_sni.py`).
///
/// The menu lists the five most recently played games, then "Open Faugus" and "Quit". It is
/// rebuilt every time it opens, so it never needs the D-Bus `RefreshMenu` call upstream uses.
@MainActor
final class TrayController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var isMonochrome = false

    /// Supplies the games (hidden ones included) and the translator at the moment the menu opens.
    var menuContent: () -> (games: [Game], translate: Translator) = { ([], .identity) }
    var isGameRunning: (String) -> Bool = { _ in false }
    var launchGame: (String) -> Void = { _ in }
    var openLauncher: () -> Void = {}
    var quitLauncher: () -> Void = {}

    var isVisible: Bool {
        statusItem != nil
    }

    func apply(enabled: Bool, monochrome: Bool) {
        guard enabled else {
            remove()
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            item.button?.toolTip = "Faugus"
            statusItem = item
            isMonochrome = !monochrome // forces the icon below to be drawn
        }
        if monochrome != isMonochrome {
            isMonochrome = monochrome
            statusItem?.button?.image = Self.icon(monochrome: monochrome)
        }
    }

    private func remove() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let content = menuContent()
        let recentGames = TrayEntries.recentGames(from: content.games)
        for entry in recentGames {
            let item = NSMenuItem(title: entry.title, action: #selector(launchSelectedGame(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.gameID
            // A running game cannot be started twice (upstream `on_launch` returns early).
            item.isEnabled = !isGameRunning(entry.gameID)
            menu.addItem(item)
        }
        if !recentGames.isEmpty {
            menu.addItem(.separator())
        }
        let openItem = NSMenuItem(
            title: content.translate("Open Faugus"),
            action: #selector(openSelected),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)
        let quitItem = NSMenuItem(title: content.translate("Quit"), action: #selector(quitSelected), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func launchSelectedGame(_ sender: NSMenuItem) {
        guard let gameID = sender.representedObject as? String else { return }
        launchGame(gameID)
    }

    @objc private func openSelected() {
        openLauncher()
    }

    @objc private func quitSelected() {
        quitLauncher()
    }

    // MARK: Icon

    /// `faugus-mono.svg` as a template image (the system tints it for light and dark menu bars),
    /// or the colour launcher icon.
    private static func icon(monochrome: Bool) -> NSImage? {
        let assets = Bundle.main.resourceURL?.appendingPathComponent("assets")
        let iconSize = NSSize(width: 18, height: 18)
        if monochrome {
            let monoImage = assets.flatMap { NSImage(contentsOf: $0.appendingPathComponent("faugus-mono.svg")) }
                ?? NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: "Faugus")
            monoImage?.size = iconSize
            monoImage?.isTemplate = true
            return monoImage
        }
        let colorImage = assets.flatMap { NSImage(contentsOf: $0.appendingPathComponent("faugus-launcher-raster.png")) }
            ?? NSApp.applicationIconImage
        colorImage?.size = iconSize
        colorImage?.isTemplate = false
        return colorImage
    }
}
