import Foundation

/// `perform_backup` from `backup_daemon.py`.
public struct BackupSession: Sendable {
    public let paths: FaugusPaths

    public init(paths: FaugusPaths) {
        self.paths = paths
    }

    /// Builds the staging tree, tars it, and moves the archive to `destinationPath`.
    /// Returns the `backup-last-date` stamp.
    public func perform(
        destinationPath: String,
        selection: BackupSelection,
        games: [Game],
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) async throws -> String {
        try await BackupLock.withExclusiveLock(paths: paths) {
            try await writeArchive(
                destinationPath: destinationPath, selection: selection, games: games, now: now, timeZone: timeZone
            )
        }
    }

    private func writeArchive(
        destinationPath: String,
        selection: BackupSelection,
        games: [Game],
        now: Date,
        timeZone: TimeZone
    ) async throws -> String {
        let staging = paths.backupStagingDirectory
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: staging) {
            try fileManager.removeItem(atPath: staging)
        }
        try fileManager.createDirectory(atPath: staging, withIntermediateDirectories: true)

        do {
            var manifest = BackupManifest()
            let selectedIDs = Set(selection.gameIDs)
            let selectedGames = games.filter { selectedIDs.contains($0.gameID) }
            manifest.games = selectedGames.map {
                BackupManifestEntry(gameID: $0.gameID, title: $0.title.isEmpty ? $0.gameID : $0.title)
            }
            try BackupLock.throwIfCancelled(paths: paths)
            try copySettings(to: staging + "/settings", games: selectedGames)

            for item in selection.prefixes {
                try BackupLock.throwIfCancelled(paths: paths)
                if item.hasPrefix, FileManager.default.fileExists(atPath: item.path) {
                    try BackupCopy.cloneOrCopy(
                        from: item.path, to: staging + "/prefixes/" + item.gameID, preserveSymlinks: true
                    )
                }
                manifest.prefixes.append(
                    BackupManifestEntry(gameID: item.gameID, title: item.title, originalPath: item.path)
                )
            }

            for item in selection.shortcuts {
                try BackupLock.throwIfCancelled(paths: paths)
                let groupDirectory = staging + "/shortcuts/" + item.gameID
                if !item.shortcutFiles.isEmpty {
                    try fileManager.createDirectory(atPath: groupDirectory, withIntermediateDirectories: true)
                    for bundlePath in item.shortcutFiles {
                        let name = (bundlePath as NSString).lastPathComponent
                        try BackupCopy.cloneOrCopy(from: bundlePath, to: groupDirectory + "/" + name)
                    }
                }
                if item.gameID == BackupInventory.defaultPrefixID,
                   fileManager.fileExists(atPath: paths.shortcutIconsDirectory)
                {
                    try BackupCopy.cloneOrCopy(
                        from: paths.shortcutIconsDirectory, to: groupDirectory + "/icons"
                    )
                }
                manifest.shortcuts.append(
                    BackupManifestShortcut(
                        gameID: item.gameID, title: item.title, originalPaths: item.shortcutFiles
                    )
                )
            }

            for item in selection.runners {
                try BackupLock.throwIfCancelled(paths: paths)
                if fileManager.fileExists(atPath: item.path) {
                    try BackupCopy.cloneOrCopy(
                        from: item.path, to: staging + "/protons/" + item.gameID, preserveSymlinks: true
                    )
                }
                manifest.protons.append(
                    BackupManifestEntry(gameID: item.gameID, title: item.title, originalPath: item.path)
                )
            }

            try BackupLock.throwIfCancelled(paths: paths)
            try JSONFile.save(manifest.json(), to: staging + "/" + BackupFormat.manifestName)
            try BackupFormat.markerText.write(
                toFile: staging + "/" + BackupFormat.markerName, atomically: true, encoding: .utf8
            )

            let archiveName = BackupFormat.archiveFileName(now: now, timeZone: timeZone)
            let packedPath = paths.tempDirectory + "/" + (archiveName as NSString).deletingPathExtension + ".tar"
            if fileManager.fileExists(atPath: packedPath) {
                try fileManager.removeItem(atPath: packedPath)
            }
            try await BackupArchive.createArchive(from: staging, to: packedPath)
            try fileManager.removeItem(atPath: staging)

            let expandedDestination = paths.expand(destinationPath)
            try fileManager.createDirectory(
                atPath: (expandedDestination as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            var finalPath = expandedDestination
            if fileManager.fileExists(atPath: finalPath) {
                finalPath = BackupFormat.uniqueArchivePath(
                    in: (expandedDestination as NSString).deletingLastPathComponent,
                    fileName: (expandedDestination as NSString).lastPathComponent,
                    now: now,
                    timeZone: timeZone
                )
            }
            try fileManager.moveItem(atPath: packedPath, toPath: finalPath)
            return BackupFormat.lastBackupStamp(now: now, timeZone: timeZone)
        } catch {
            try? fileManager.removeItem(atPath: staging)
            throw error
        }
    }

    private func copySettings(to settingsDirectory: String, games: [Game]) throws {
        let fileManager = FileManager.default
        let includedImages = BackupInventory.imageBasenames(games: games)
        let dataDirectory = settingsDirectory + "/data"
        try fileManager.createDirectory(atPath: dataDirectory, withIntermediateDirectories: true)
        try JSONFile.save(.array(games.map { .object($0.saveObject()) }), to: dataDirectory + "/games.json")

        let roots: [(name: String, path: String)] = [
            ("config", paths.configDirectory),
            ("data", paths.dataDirectory),
            ("state", paths.stateDirectory),
        ]
        for root in roots {
            try BackupLock.throwIfCancelled(paths: paths)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            let destinationRoot = settingsDirectory + "/" + root.name
            let entries = try fileManager.contentsOfDirectory(atPath: root.path)
            for name in entries {
                let sourcePath = root.path + "/" + name
                let targetPath = destinationRoot + "/" + name
                try fileManager.createDirectory(atPath: destinationRoot, withIntermediateDirectories: true)
                if name == "games.json" {
                    continue
                } else if ["covers", "banners", "icons"].contains(name) {
                    try BackupCopy.copyMatching(from: sourcePath, to: targetPath, includedNames: includedImages)
                } else {
                    try BackupCopy.cloneOrCopy(from: sourcePath, to: targetPath, preserveSymlinks: true)
                }
            }
        }
    }
}

public struct BackupRestore: Sendable {
    public let paths: FaugusPaths

    public init(paths: FaugusPaths) {
        self.paths = paths
    }

    public struct Preview: Equatable, Sendable {
        public var stagingDirectory: String
        public var manifest: BackupManifest?
        public var isLegacy: Bool
        public var prefixItems: [BackupPrefixItem]
        public var runnerItems: [BackupRunnerItem]
    }

    /// Extracts `archivePath` into the restore staging directory and reads the manifest.
    public func preview(archivePath: String) async throws -> Preview {
        let staging = paths.restoreStagingDirectory
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: staging) {
            try fileManager.removeItem(atPath: staging)
        }
        try await BackupArchive.extract(archivePath: archivePath, to: staging)
        guard BackupArchive.isFaugusBackup(stagingDirectory: staging) else {
            try? fileManager.removeItem(atPath: staging)
            throw BackupError.invalidArchive
        }
        let manifestPath = staging + "/" + BackupFormat.manifestName
        if fileManager.fileExists(atPath: manifestPath) {
            let json = JSONFile.load(manifestPath, default: .object(JSONObject()))
            let manifest = BackupManifest(json: json) ?? BackupManifest()
            return Preview(
                stagingDirectory: staging,
                manifest: manifest,
                isLegacy: false,
                prefixItems: BackupRestore.prefixItems(from: manifest, staging: staging),
                runnerItems: BackupRestore.runnerItems(from: manifest, staging: staging)
            )
        }
        return Preview(
            stagingDirectory: staging, manifest: nil, isLegacy: true, prefixItems: [], runnerItems: []
        )
    }

    public func restore(
        preview: Preview,
        selectedGameIDs: Set<String>,
        selectedPrefixes: [BackupPrefixItem],
        selectedShortcuts: [BackupPrefixItem],
        selectedRunners: [BackupRunnerItem],
        macUserName: String = NSUserName(),
        runner: InstalledRunner? = nil
    ) throws -> LinuxFixup.Result {
        if preview.isLegacy {
            try restoreLegacyFlat(stagingDirectory: preview.stagingDirectory)
        } else {
            try restoreSettings(
                settingsDirectory: preview.stagingDirectory + "/settings", selectedGameIDs: selectedGameIDs
            )
            try restoreShortcuts(staging: preview.stagingDirectory, items: selectedShortcuts)
            for item in selectedPrefixes {
                try restoreTree(
                    staging: preview.stagingDirectory, category: "prefixes", gameID: item.gameID,
                    originalPath: item.path
                )
            }
            for item in selectedRunners where !LinuxFixup.looksLikeLinuxPath(item.path) {
                try restoreTree(
                    staging: preview.stagingDirectory, category: "protons", gameID: item.gameID,
                    originalPath: item.path
                )
            }
        }
        let outcome = try LinuxFixup.apply(paths: paths, macUserName: macUserName, runner: runner)
        try? FileManager.default.removeItem(atPath: preview.stagingDirectory)
        return outcome
    }

    public func discard(preview: Preview) {
        try? FileManager.default.removeItem(atPath: preview.stagingDirectory)
    }

    public func restoreLegacyFlat(stagingDirectory: String) throws {
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(atPath: stagingDirectory)) ?? []
        for name in entries where name != BackupFormat.markerName {
            try restoreFlatItem(name, from: stagingDirectory + "/" + name, wipeExisting: true)
        }
    }

    private func restoreSettings(settingsDirectory: String, selectedGameIDs: Set<String>) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: settingsDirectory) else { return }
        let keep = URL(fileURLWithPath: paths.tempDirectory).standardizedFileURL.path
        for root in [paths.configDirectory, paths.dataDirectory, paths.stateDirectory] {
            try BackupCopy.wipeContents(of: root, skipping: keep)
        }

        let nested = BackupFormat.settingsRoots.contains {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: settingsDirectory + "/" + $0, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }

        let gamesJSONPath = nested
            ? settingsDirectory + "/data/games.json" : settingsDirectory + "/games.json"
        let filtered = filterGames(at: gamesJSONPath, selectedIDs: selectedGameIDs)
        let includedImages = BackupInventory.imageBasenames(games: filtered)

        if nested {
            let roots: [(name: String, path: String)] = [
                ("config", paths.configDirectory),
                ("data", paths.dataDirectory),
                ("state", paths.stateDirectory),
            ]
            for root in roots {
                let sourceRoot = settingsDirectory + "/" + root.name
                guard fileManager.fileExists(atPath: sourceRoot) else { continue }
                try fileManager.createDirectory(atPath: root.path, withIntermediateDirectories: true)
                let entries = (try? fileManager.contentsOfDirectory(atPath: sourceRoot)) ?? []
                for name in entries {
                    let sourcePath = sourceRoot + "/" + name
                    let targetPath = root.path + "/" + name
                    if name == "games.json" {
                        try JSONFile.save(.array(filtered.map { .object($0.saveObject()) }), to: targetPath)
                    } else if ["covers", "banners", "icons"].contains(name) {
                        try BackupCopy.copyMatching(from: sourcePath, to: targetPath, includedNames: includedImages)
                    } else {
                        try BackupCopy.cloneOrCopy(from: sourcePath, to: targetPath, preserveSymlinks: true)
                    }
                }
            }
            return
        }

        let entries = (try? fileManager.contentsOfDirectory(atPath: settingsDirectory)) ?? []
        for name in entries {
            let sourcePath = settingsDirectory + "/" + name
            if name == "games.json" {
                try JSONFile.save(.array(filtered.map { .object($0.saveObject()) }), to: paths.gamesJSON)
            } else if ["covers", "banners", "icons"].contains(name) {
                try BackupCopy.copyMatching(
                    from: sourcePath, to: flatDestination(name) ?? sourcePath, includedNames: includedImages
                )
            } else {
                try restoreFlatItem(name, from: sourcePath, wipeExisting: false)
            }
        }
    }

    private func restoreShortcuts(staging: String, items: [BackupPrefixItem]) throws {
        let fileManager = FileManager.default
        for item in items {
            let sourceDirectory = staging + "/shortcuts/" + item.gameID
            guard fileManager.fileExists(atPath: sourceDirectory) else { continue }
            for originalPath in item.shortcutFiles {
                if originalPath.hasSuffix(".desktop") {
                    continue
                }
                let sourcePath = sourceDirectory + "/" + (originalPath as NSString).lastPathComponent
                let destinationPath = macPath(originalPath, gameID: item.gameID)
                guard fileManager.fileExists(atPath: sourcePath) else { continue }
                try fileManager.createDirectory(
                    atPath: (destinationPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true
                )
                try BackupCopy.cloneOrCopy(from: sourcePath, to: destinationPath, preserveSymlinks: true)
            }
            if item.gameID == BackupInventory.defaultPrefixID {
                let iconsSource = sourceDirectory + "/icons"
                if fileManager.fileExists(atPath: iconsSource) {
                    try BackupCopy.cloneOrCopy(from: iconsSource, to: paths.shortcutIconsDirectory)
                }
            }
        }
    }

    private func restoreTree(staging: String, category: String, gameID: String, originalPath: String) throws {
        let source = staging + "/" + category + "/" + gameID
        let destination = macPath(originalPath, gameID: gameID)
        guard FileManager.default.fileExists(atPath: source), !destination.isEmpty else { return }
        try BackupCopy.replaceDirectory(from: source, to: destination)
    }

    private func restoreFlatItem(_ name: String, from sourcePath: String, wipeExisting: Bool) throws {
        guard let destination = flatDestination(name) else { return }
        let fileManager = FileManager.default
        if wipeExisting, fileManager.fileExists(atPath: destination) {
            try fileManager.removeItem(atPath: destination)
        }
        try fileManager.createDirectory(
            atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try BackupCopy.cloneOrCopy(from: sourcePath, to: destination, preserveSymlinks: true)
    }

    private func flatDestination(_ name: String) -> String? {
        switch name {
        case "covers": paths.coversDirectory
        case "banners", "heroes": paths.bannersDirectory
        case "games-backup": paths.gamesBackupDirectory
        case "icons": paths.iconsDirectory
        case "config.json": paths.configFile
        case "envar.json": paths.environmentVariablesFile
        case "games.json": paths.gamesJSON
        case "latest-games.json": paths.latestGamesFile
        case "recent-run-files.json": paths.recentRunFilesFile
        case "categories.json": paths.categoriesFile
        case "custom-order.json": paths.customOrderFile
        case "presets.json": paths.presetsFile
        case "filechooser_folders.json": paths.fileChooserFoldersFile
        default: nil
        }
    }

    private func filterGames(at path: String, selectedIDs: Set<String>) -> [Game] {
        let entries = JSONFile.load(path, default: .array([])).arrayValue ?? []
        return entries.compactMap { entry in
            guard let object = entry.objectValue else { return nil }
            let game = Game(json: object)
            return selectedIDs.contains(game.gameID) ? game : nil
        }
    }

    private func macPath(_ originalPath: String, gameID: String) -> String {
        let rewritten = LinuxFixup.rewriteLinuxPath(originalPath, paths: paths)
        if LinuxFixup.looksLikeLinuxPath(rewritten) {
            return paths.prefixesDirectory + "/" + gameID
        }
        return rewritten
    }

    static func prefixItems(from manifest: BackupManifest, staging: String) -> [BackupPrefixItem] {
        let shortcutsByID = Dictionary(uniqueKeysWithValues: manifest.shortcuts.map { ($0.gameID, $0) })
        var items: [BackupPrefixItem] = []
        var seen = Set<String>()
        for entry in manifest.prefixes {
            seen.insert(entry.gameID)
            let source = staging + "/prefixes/" + entry.gameID
            let hasPrefix = FileManager.default.fileExists(atPath: source)
            items.append(
                BackupPrefixItem(
                    gameID: entry.gameID,
                    title: entry.title,
                    path: entry.originalPath,
                    hasPrefix: hasPrefix,
                    shortcutFiles: shortcutsByID[entry.gameID]?.originalPaths ?? [],
                    sizeBytes: hasPrefix ? BackupCopy.directorySize(at: source) : 0
                )
            )
        }
        for group in manifest.shortcuts where !seen.contains(group.gameID) {
            seen.insert(group.gameID)
            items.append(
                BackupPrefixItem(
                    gameID: group.gameID, title: group.title, path: "", hasPrefix: false,
                    shortcutFiles: group.originalPaths
                )
            )
        }
        for entry in manifest.games where !seen.contains(entry.gameID) {
            seen.insert(entry.gameID)
            items.append(BackupPrefixItem(gameID: entry.gameID, title: entry.title, path: "", hasPrefix: false))
        }
        return items
    }

    static func runnerItems(from manifest: BackupManifest, staging: String) -> [BackupRunnerItem] {
        manifest.protons.map { entry in
            let source = staging + "/protons/" + entry.gameID
            return BackupRunnerItem(
                gameID: entry.gameID,
                title: entry.title,
                path: entry.originalPath,
                sizeBytes: FileManager.default.fileExists(atPath: source) ? BackupCopy.directorySize(at: source) : 0
            )
        }
    }
}
