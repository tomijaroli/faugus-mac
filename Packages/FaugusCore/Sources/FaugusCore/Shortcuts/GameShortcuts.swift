import Foundation

/// Port of upstream `add_shortcut` / `remove_shortcut` / `check_existing_shortcut` for saved
/// games: a stub `.app` per location that runs `Faugus --game <gameid>` from the game's folder.
public struct GameShortcuts: Sendable {
    public typealias Location = ShortcutLocation

    private let library: ShortcutLibrary

    public init(paths: FaugusPaths, executablePath: String, fallbackIconPath: String) {
        library = ShortcutLibrary(paths: paths, executablePath: executablePath, fallbackIconPath: fallbackIconPath)
    }

    public var paths: FaugusPaths {
        library.paths
    }

    /// The command the stub runs for `game`: `Faugus --game <gameid>` from the game's folder.
    public func launch(for game: Game) -> ShortcutLaunch {
        let gameDirectory = (paths.expand(game.path) as NSString).deletingLastPathComponent
        return ShortcutLaunch(
            executablePath: library.executablePath,
            arguments: ["--game", game.gameID],
            workingDirectory: gameDirectory.isEmpty ? nil : gameDirectory
        )
    }

    /// Writes the shortcut for `game` into each of `locations` and returns the bundle paths.
    /// `iconPath` defaults to the game's saved icon (`icons/<gameid>.png`, upstream's
    /// `ICONS_DIR`); the fallback icon is used when it is missing or unreadable.
    @discardableResult
    public func install(
        for game: Game,
        locations: Set<Location>,
        iconPath: String? = nil
    ) throws -> [Location: String] {
        try library.install(
            marker: ShortcutMarker(gameID: game.gameID, kind: .game),
            title: game.title,
            launch: launch(for: game),
            locations: locations,
            iconPath: iconPath ?? savedIconPath(gameID: game.gameID)
        )
    }

    /// Deletes the game's shortcut bundles (found by marker, not by name) and returns the
    /// locations that had one. Bundles without the Faugus marker are never touched.
    @discardableResult
    public func remove(
        gameID: String,
        locations: Set<Location> = Set(Location.allCases)
    ) throws -> Set<Location> {
        try library.remove(marker: ShortcutMarker(gameID: gameID, kind: .game), locations: locations)
    }

    /// The locations that currently hold a shortcut for `gameID` (upstream
    /// `check_existing_shortcut`), found by scanning markers.
    public func existingLocations(gameID: String) -> Set<Location> {
        library.existingLocations(gameID: gameID, kind: .game)
    }

    /// After a game was edited or renamed: re-renders its existing shortcuts (moving them to
    /// the new title) and keeps the set of locations. Returns the locations updated.
    @discardableResult
    public func update(for game: Game, iconPath: String? = nil) throws -> Set<Location> {
        let locations = existingLocations(gameID: game.gameID)
        guard !locations.isEmpty else { return [] }
        try install(for: game, locations: locations, iconPath: iconPath)
        return locations
    }

    private func savedIconPath(gameID: String) -> String {
        paths.iconsDirectory + "/" + gameID + ".png"
    }
}
