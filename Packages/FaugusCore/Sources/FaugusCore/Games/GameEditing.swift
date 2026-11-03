import Foundation

/// The rules behind upstream's Add, Edit, Duplicate and Delete flows that do not depend on the UI.
public enum GameEditing {
    // MARK: Validation

    public enum InvalidField: Equatable, Sendable { case title, path, prefix }

    /// `validate_fields` for the Steam type: a game must be chosen (its app id is the path).
    public static func steamSelectionMissing(appID: String) -> Bool {
        appID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// `validate_fields("path+prefix")`: the title and its formatted ID, the path and the prefix
    /// must be non-empty.
    public static func invalidFields(title: String, path: String, prefix: String) -> [InvalidField] {
        var fields: [InvalidField] = []
        if title.isEmpty || GameID.format(title: title).isEmpty {
            fields.append(.title)
        }
        if path.isEmpty {
            fields.append(.path)
        }
        if prefix.isEmpty {
            fields.append(.prefix)
        }
        return fields
    }

    /// "%s already exists": case-insensitive match against every other game's title.
    public static func titleExists(_ title: String, in games: [Game], ignoring gameID: String? = nil) -> Bool {
        games.contains { $0.gameID != gameID && $0.title.caseInsensitiveCompare(title) == .orderedSame }
    }

    /// `os.path.normpath`.
    public static func normalizedPath(_ path: String) -> String {
        guard !path.isEmpty else { return "." }
        let isAbsolute = path.hasPrefix("/")
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." {
                continue
            }
            if part == ".." {
                if let last = parts.last, last != ".." {
                    parts.removeLast()
                } else if !isAbsolute {
                    parts.append(part)
                }
            } else {
                parts.append(part)
            }
        }
        let joined = parts.joined(separator: "/")
        if isAbsolute {
            return "/" + joined
        }
        return joined.isEmpty ? "." : joined
    }

    // MARK: Save

    /// What the Add / Edit dialog collects (Windows or Steam game type).
    public struct Draft: Sendable {
        /// Non-nil makes it a Steam-type game for that Steam account ("" when none is chosen);
        /// `path` is then the Steam app id.
        public var steamUser: String?
        public var title = ""
        public var path = ""
        public var prefix = ""
        public var customRunner = false
        public var runner = "Default"
        public var graphics: GraphicsBackend = .default
        public var launchArguments: [String] = []
        public var gameArguments = ""
        public var preLaunch = ""
        public var postLaunch = ""
        public var discordRPC = false
        public var noSleep = false
        public var sdlEnabled = false
        public var addAppEnabled = false
        public var addAppPath = ""
        public var addAppDelay = 0
        public var addAppFirst = false
        public init() {}
    }

    /// `on_dialog_response` / `on_edit_dialog_response`: writes the draft into `game`. The game
    /// ID of an existing game never changes. Fields the dialog does not edit are kept.
    public static func apply(_ draft: Draft, to game: Game, paths: FaugusPaths) -> Game {
        var updatedGame = game
        updatedGame.title = draft.title
        updatedGame.path = draft.path
        updatedGame.prefix = normalizedPath(draft.prefix)
        updatedGame.runner = draft.customRunner ? draft.runner : "Default"
        updatedGame.graphics = draft.graphics == .default ? nil : draft.graphics
        updatedGame.launchArguments = LaunchArgumentLines.join(draft.launchArguments)
        updatedGame.gameArguments = draft.gameArguments
        updatedGame.preLaunch = draft.preLaunch.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedGame.postLaunch = draft.postLaunch.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedGame.sdlEnabled = draft.sdlEnabled
        updatedGame.noSleep = draft.noSleep
        updatedGame.discordRPC = draft.discordRPC
        updatedGame.addAppEnabled = draft.addAppEnabled
        updatedGame.addApp = draft.addAppPath
        updatedGame.addAppDelay = String(draft.addAppDelay)
        updatedGame.addAppFirst = draft.addAppFirst
        updatedGame.addAppBat = addAppBatPath(gamePath: updatedGame.path, gameID: updatedGame.gameID, paths: paths)
        if let user = draft.steamUser {
            // Steam owns the game: Wine-side options are cleared, as upstream does.
            updatedGame.runner = "Steam"
            updatedGame.graphics = nil
            updatedGame.steamUser = user
            updatedGame.mangohud = false
            updatedGame.gamemode = false
            updatedGame.sdlEnabled = false
            updatedGame.noSleep = false
            updatedGame.discordRPC = false
            updatedGame.addAppEnabled = false
            updatedGame.addApp = ""
            updatedGame.addAppBat = ""
        } else {
            updatedGame.steamUser = ""
        }
        return updatedGame
    }

    // MARK: Additional application

    /// `write_addapp_bat`: the batch file that starts the game and the extra application. The
    /// `z:` drive is Wine's view of the Unix root.
    public static func addAppBatContents(
        executable: String, addApp: String, delay: String, first: Bool, gameArguments: String
    ) -> String {
        let gameLine = gameArguments.isEmpty ? "start \"\" \"z:\(executable)\"\n" : "start \"\" \"z:\(executable)\" \(gameArguments)\n"
        let addAppLine = "start \"\" \"z:\(addApp)\"\n"
        let (firstLine, secondLine) = first ? (addAppLine, gameLine) : (gameLine, addAppLine)
        var contents = "@echo off\n" + firstLine
        if !delay.isEmpty, delay != "0" {
            contents += "ping -n \(delay) 127.0.0.1 >nul\n"
        }
        return contents + secondLine
    }

    /// `faugus-<id>.bat` next to the game's executable.
    public static func addAppBatPath(gamePath: String, gameID: String, paths: FaugusPaths) -> String {
        let directory = (paths.expand(gamePath) as NSString).deletingLastPathComponent
        return "\(directory)/faugus-\(gameID).bat"
    }

    public static func writeAddAppBat(for game: Game, paths: FaugusPaths) throws {
        let contents = addAppBatContents(
            executable: paths.expand(game.path), addApp: paths.expand(game.addApp), delay: game.addAppDelay,
            first: game.addAppFirst,
            gameArguments: game.gameArguments
        )
        let path = paths.expand(game.addAppBat)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: Delete

    /// Files that belong to a game and go away with it (`remove_cover_icon`, the add-app bat).
    public static func artworkFiles(for gameID: String, paths: FaugusPaths) -> [String] {
        [paths.coversDirectory, paths.iconsDirectory, paths.bannersDirectory].map { "\($0)/\(gameID).png" }
    }

    /// Removes the artwork and the generated bat. Never touches the prefix or the game itself.
    public static func removeOwnedFiles(of game: Game, paths: FaugusPaths) {
        let fileManager = FileManager.default
        for artworkFile in artworkFiles(for: game.gameID, paths: paths)
            where fileManager.fileExists(atPath: artworkFile)
        {
            try? fileManager.removeItem(atPath: artworkFile)
        }
        let batchFile = paths.expand(game.addAppBat)
        // Only generated `faugus-*.bat` files are removed.
        if !batchFile.isEmpty, (batchFile as NSString).lastPathComponent.hasPrefix("faugus-"),
           fileManager.fileExists(atPath: batchFile)
        {
            try? fileManager.removeItem(atPath: batchFile)
        }
    }

    /// `DeleteDialog`: the prefix checkbox is offered unless the prefix is named `default`, the
    /// game is a Steam game, or another game still uses the prefix. Returns how many others do.
    public static func otherGamesUsingPrefix(of game: Game, in games: [Game], paths: FaugusPaths) -> Int {
        let prefix = paths.expand(game.prefix)
        guard !prefix.isEmpty else { return 0 }
        return games.filter { $0.gameID != game.gameID && paths.expand($0.prefix) == prefix }.count
    }

    public static func offersPrefixRemoval(for game: Game, paths: FaugusPaths) -> Bool {
        let prefix = paths.expand(game.prefix)
        return !prefix.isEmpty && (prefix as NSString).lastPathComponent != "default"
            && game.runner != "Steam" && game.runner != "Linux-Native"
    }

    // MARK: Duplicate

    public enum DuplicateError: Error, Equatable { case invalidTitle, exists }

    /// `_on_confirm_duplicate_response`: a copy under a new title and ID, with its icon, cover,
    /// banner and add-app bat copied. Category, playtime and the rest are copied as they are.
    public static func duplicate(
        _ game: Game, newTitle rawTitle: String, existing: [Game], paths: FaugusPaths
    ) throws -> Game {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = GameID.format(title: title)
        if title.isEmpty || base.isEmpty {
            throw DuplicateError.invalidTitle
        }
        if titleExists(title, in: existing) {
            throw DuplicateError.exists
        }
        let id = GameID.unique(base: base, existing: Set(existing.map(\.gameID)))
        let fileManager = FileManager.default

        var copy = game
        copy.gameID = id
        copy.title = title

        let oldIcon = paths.expand(game.icon)
        let newIcon = "\(paths.iconsDirectory)/\(id).png"
        if !oldIcon.isEmpty, fileManager.fileExists(atPath: oldIcon) {
            try? fileManager.createDirectory(atPath: paths.iconsDirectory, withIntermediateDirectories: true)
            try? fileManager.removeItem(atPath: newIcon)
            try? fileManager.copyItem(atPath: oldIcon, toPath: newIcon)
        }
        copy.icon = newIcon

        let oldCover = paths.expand(game.cover)
        let newCover = "\(paths.coversDirectory)/\(id).png"
        if !oldCover.isEmpty, fileManager.fileExists(atPath: oldCover) {
            try? fileManager.createDirectory(atPath: paths.coversDirectory, withIntermediateDirectories: true)
            try? fileManager.removeItem(atPath: newCover)
            try? fileManager.copyItem(atPath: oldCover, toPath: newCover)
            copy.cover = newCover
        } else {
            copy.cover = ""
        }

        let oldBanner = "\(paths.bannersDirectory)/\(game.gameID).png"
        if fileManager.fileExists(atPath: oldBanner) {
            try? fileManager.createDirectory(atPath: paths.bannersDirectory, withIntermediateDirectories: true)
            let newBanner = "\(paths.bannersDirectory)/\(id).png"
            try? fileManager.removeItem(atPath: newBanner)
            try? fileManager.copyItem(atPath: oldBanner, toPath: newBanner)
        }

        let newBatchFile = addAppBatPath(gamePath: game.path, gameID: id, paths: paths)
        let oldBatchFile = paths.expand(game.addAppBat)
        if !oldBatchFile.isEmpty, fileManager.fileExists(atPath: oldBatchFile) {
            try? fileManager.removeItem(atPath: newBatchFile)
            try? fileManager.copyItem(atPath: oldBatchFile, toPath: newBatchFile)
        }
        copy.addAppBat = newBatchFile
        return copy
    }
}

/// `presets.json`: reusable launch arguments.
public struct PresetsStore: Sendable {
    public let paths: FaugusPaths
    public init(paths: FaugusPaths) {
        self.paths = paths
    }

    public func load() -> [String] {
        guard case let .array(items) = JSONFile.load(paths.presetsFile, default: .array([])) else { return [] }
        return items.compactMap(\.stringValue)
    }

    public func save(_ presets: [String]) throws {
        let kept = presets.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        try JSONFile.save(.array(kept.map { .string($0) }), to: paths.presetsFile)
    }
}

/// The launch arguments field holds one argument per line (`LaunchArgumentsEditor`).
public enum LaunchArgumentLines {
    public static func split(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    public static func join(_ lines: [String]) -> String {
        lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
    }
}
