import FaugusCore
import Foundation

/// Desktop shortcuts and SteamGridDB, the two P4 services the Add / Edit dialog drives.
extension AppModel {
    // MARK: Shortcuts

    var fallbackIconPath: String {
        Bundle.main.resourceURL?.appendingPathComponent("assets/faugus-launcher-raster.png").path ?? ""
    }

    var gameShortcuts: GameShortcuts {
        GameShortcuts(
            paths: paths,
            executablePath: Bundle.main.executablePath ?? CommandLine.arguments[0],
            fallbackIconPath: fallbackIconPath
        )
    }

    /// `check_existing_shortcut`: where the game already has a shortcut.
    func shortcutLocations(of game: Game?) -> Set<ShortcutLocation> {
        guard let game else { return [] }
        return gameShortcuts.existingLocations(gameID: game.gameID)
    }

    /// The Desktop and App Menu checkboxes of the dialog: shortcuts that are no longer wanted are
    /// removed, the wanted ones are (re)written so a rename or a new icon reaches them.
    func applyShortcuts(for game: Game, wanted: Set<ShortcutLocation>) {
        let shortcuts = gameShortcuts
        do {
            let unwanted = shortcuts.existingLocations(gameID: game.gameID).subtracting(wanted)
            if !unwanted.isEmpty {
                try shortcuts.remove(gameID: game.gameID, locations: unwanted)
            }
            if !wanted.isEmpty {
                try shortcuts.install(for: game, locations: wanted)
            }
        } catch {
            actionError = "\(translator("Failed to create shortcut")): \(error)"
        }
    }

    func removeShortcuts(ofGameID gameID: String) {
        _ = try? gameShortcuts.remove(gameID: gameID)
    }

    // MARK: SteamGridDB

    /// `steamgriddb_enabled` of the dialogs: switched on in Settings and an API key is present.
    var steamGridDBSettings: SteamGridDBSettings? {
        config.map { SteamGridDBSettings(configuration: $0) }
    }

    var steamGridDBClient: SteamGridDBClient? {
        steamGridDBSettings?.makeClient()
    }
}
