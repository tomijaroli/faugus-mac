import Foundation

/// One row of the Backup/Restore prefix list (`list_game_prefixes_with_shortcuts`).
public struct BackupPrefixItem: Equatable, Sendable, Identifiable {
    public var gameID: String
    public var title: String
    public var path: String
    public var hasPrefix: Bool
    public var shortcutFiles: [String]
    public var sizeBytes: Int64

    public var id: String {
        gameID
    }

    public init(
        gameID: String,
        title: String,
        path: String,
        hasPrefix: Bool,
        shortcutFiles: [String] = [],
        sizeBytes: Int64 = 0
    ) {
        self.gameID = gameID
        self.title = title
        self.path = path
        self.hasPrefix = hasPrefix
        self.shortcutFiles = shortcutFiles
        self.sizeBytes = sizeBytes
    }
}

/// One installed runner row (`list_installed_protons` → Mac runners).
public struct BackupRunnerItem: Equatable, Sendable, Identifiable {
    public var gameID: String
    public var title: String
    public var path: String
    public var sizeBytes: Int64

    public var id: String {
        gameID
    }

    public init(gameID: String, title: String, path: String, sizeBytes: Int64 = 0) {
        self.gameID = gameID
        self.title = title
        self.path = path
        self.sizeBytes = sizeBytes
    }
}

/// What `perform_backup` copies besides settings.
public struct BackupSelection: Equatable, Sendable {
    public var gameIDs: [String]
    public var prefixes: [BackupPrefixItem]
    public var shortcuts: [BackupPrefixItem]
    public var runners: [BackupRunnerItem]

    public init(
        gameIDs: [String] = [],
        prefixes: [BackupPrefixItem] = [],
        shortcuts: [BackupPrefixItem] = [],
        runners: [BackupRunnerItem] = []
    ) {
        self.gameIDs = gameIDs
        self.prefixes = prefixes
        self.shortcuts = shortcuts
        self.runners = runners
    }
}

public enum BackupInventory {
    public static let defaultPrefixID = "default"

    /// `list_game_prefixes`: Steam games skipped; default prefix inserted first when it exists.
    public static func prefixItems(paths: FaugusPaths, configuration: FaugusConfig, games: [Game]) -> [BackupPrefixItem]
    {
        var items: [BackupPrefixItem] = []
        for game in games {
            if game.runner == "Steam" {
                continue
            }
            let prefix = paths.expand(game.prefix)
            guard !game.gameID.isEmpty, !prefix.isEmpty else { continue }
            items.append(
                BackupPrefixItem(
                    gameID: game.gameID,
                    title: game.title.isEmpty ? game.gameID : game.title,
                    path: prefix,
                    hasPrefix: FileManager.default.fileExists(atPath: prefix)
                )
            )
        }
        items.sort { $0.title.lowercased() < $1.title.lowercased() }

        let defaultBase = paths.expand(configuration.string("default-prefix")).trimmingCharacters(
            in: CharacterSet(charactersIn: "\"")
        )
        if !defaultBase.isEmpty {
            let defaultPath = defaultBase + "/default"
            if FileManager.default.fileExists(atPath: defaultPath) {
                items.insert(
                    BackupPrefixItem(
                        gameID: defaultPrefixID, title: "Default Prefix", path: defaultPath, hasPrefix: true
                    ),
                    at: 0
                )
            }
        }
        return items
    }

    /// Attaches Mac shortcut bundles, leftover ones on the default row (`list_game_prefixes_with_shortcuts`).
    public static func prefixItemsWithShortcuts(
        paths: FaugusPaths,
        configuration: FaugusConfig,
        games: [Game],
        executablePath: String,
        fallbackIconPath: String
    ) -> [BackupPrefixItem] {
        var items = prefixItems(paths: paths, configuration: configuration, games: games)
        let library = ShortcutLibrary(
            paths: paths, executablePath: executablePath, fallbackIconPath: fallbackIconPath
        )
        let bundles = library.allBundles()
        let knownIDs = Set(items.map(\.gameID).filter { $0 != defaultPrefixID })
        var leftovers: [String] = []
        var byGameID: [String: [String]] = [:]
        for bundle in bundles {
            if bundle.marker.kind == .game, knownIDs.contains(bundle.marker.gameID) {
                byGameID[bundle.marker.gameID, default: []].append(bundle.path)
            } else {
                leftovers.append(bundle.path)
            }
        }
        for index in items.indices {
            if items[index].gameID == defaultPrefixID {
                items[index].shortcutFiles = leftovers
            } else {
                items[index].shortcutFiles = byGameID[items[index].gameID] ?? []
            }
        }
        return items
    }

    public static func runnerItems(paths: FaugusPaths) -> [BackupRunnerItem] {
        RunnerStore(paths: paths).installed().map { runner in
            BackupRunnerItem(gameID: runner.name, title: runner.name, path: runner.directory)
        }
        .sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    public static func imageBasenames(games: [Game]) -> Set<String> {
        var names: Set<String> = []
        for game in games {
            names.insert(game.gameID + ".png")
            for field in [game.cover, game.icon] where !field.isEmpty {
                names.insert((field as NSString).lastPathComponent)
            }
        }
        return names
    }

    /// `resolve_excluded_ids`: new excluded-id keys, or invert the old included-id keys.
    public static func resolveExcludedIDs(
        configuration: FaugusConfig,
        excludedKey: String,
        includedKey: String,
        allIDs: Set<String>
    ) -> Set<String> {
        if configuration.values[excludedKey] != nil {
            return Set(stringArray(configuration, excludedKey))
        }
        if configuration.values[includedKey] != nil {
            return allIDs.subtracting(stringArray(configuration, includedKey))
        }
        return []
    }

    /// `backup_selection_from_config`.
    public static func selection(
        from configuration: FaugusConfig,
        items: [BackupPrefixItem],
        runners: [BackupRunnerItem]
    ) -> BackupSelection {
        let gameIDs = Set(items.map(\.gameID))
        let shortcutIDs = Set(items.filter { !$0.shortcutFiles.isEmpty }.map(\.gameID))
        let excludedGames = Set(stringArray(configuration, "backup-excluded-game-ids"))
        let excludedPrefixes = resolveExcludedIDs(
            configuration: configuration,
            excludedKey: "backup-excluded-prefix-ids",
            includedKey: "backup-prefix-ids",
            allIDs: gameIDs
        )
        let excludedShortcuts = resolveExcludedIDs(
            configuration: configuration,
            excludedKey: "backup-excluded-shortcut-ids",
            includedKey: "backup-shortcut-ids",
            allIDs: shortcutIDs
        )
        let runnerIDs = Set(stringArray(configuration, "backup-proton-ids"))
        return BackupSelection(
            gameIDs: items.map(\.gameID).filter { !excludedGames.contains($0) },
            prefixes: items.filter { !excludedPrefixes.contains($0.gameID) },
            shortcuts: items.filter { !$0.shortcutFiles.isEmpty && !excludedShortcuts.contains($0.gameID) },
            runners: runners.filter { runnerIDs.contains($0.gameID) }
        )
    }

    public static func estimateSize(paths: FaugusPaths, selection: BackupSelection) -> Int64 {
        var total = settingsSize(paths: paths)
        for item in selection.shortcuts {
            for filePath in item.shortcutFiles {
                total += BackupCopy.directorySize(at: filePath)
            }
        }
        for item in selection.prefixes where item.hasPrefix {
            total += BackupCopy.directorySize(at: item.path)
        }
        for item in selection.runners {
            total += BackupCopy.directorySize(at: item.path)
        }
        return total
    }

    public static func settingsSize(paths: FaugusPaths) -> Int64 {
        var combined: [String: Int64] = [:]
        for root in [paths.configDirectory, paths.dataDirectory, paths.stateDirectory] {
            combined.merge(BackupCopy.inodeMap(at: root), uniquingKeysWith: { _, new in new })
        }
        return combined.values.reduce(0, +)
    }

    public static func stringArray(_ configuration: FaugusConfig, _ key: String) -> [String] {
        configuration.values[key]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}
