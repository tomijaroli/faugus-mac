import Foundation

/// Plan §6.3: rewrite Linux paths, remap Proton runners, mark Linux-only games, and tidy prefixes.
public enum LinuxFixup {
    public static let protonGraphicsDLLs = [
        "d3d8.dll", "d3d9.dll", "d3d10core.dll", "d3d11.dll", "dxgi.dll", "d3d12.dll", "d3d12core.dll",
    ]

    public struct Result: Equatable, Sendable {
        public var importedLinux = false
        public var prefixesNeedingWineboot: [String] = []
        public var shortcutGameIDs: [String] = []
    }

    public static func isProtonRunner(_ name: String) -> Bool {
        let folded = name.lowercased()
        return folded.contains("proton") || folded.hasPrefix("ge-") || folded.hasPrefix("umu-")
    }

    public static func isLinuxOnlyRunner(_ name: String) -> Bool {
        name == "Linux-Native" || name == "Steam-Linux"
    }

    /// `/home/<user>/Faugus` and the three XDG faugus-launcher trees map onto `FaugusPaths`.
    public static func rewriteLinuxPath(_ path: String, paths: FaugusPaths) -> String {
        guard !path.isEmpty else { return path }
        let replacements: [(prefix: String, destination: String)] = [
            ("/Faugus", paths.prefixesDirectory),
            ("/.config/faugus-launcher", paths.configDirectory),
            ("/.local/share/faugus-launcher", paths.dataDirectory),
            ("/.local/state/faugus-launcher", paths.stateDirectory),
        ]
        if path.hasPrefix("/home/") {
            let afterHome = path.dropFirst("/home/".count)
            guard let slash = afterHome.firstIndex(of: "/") else { return path }
            let remainder = String(afterHome[slash...])
            for mapping in replacements where remainder == mapping.prefix || remainder.hasPrefix(mapping.prefix + "/") {
                return mapping.destination + String(remainder.dropFirst(mapping.prefix.count))
            }
        }
        return path
    }

    public static func looksLikeLinuxPath(_ path: String) -> Bool {
        path.hasPrefix("/home/")
            || path.contains("/.config/faugus-launcher")
            || path.contains("/.local/share/faugus-launcher")
            || path.contains("/.local/state/faugus-launcher")
    }

    public static func shouldReplaceGraphicsDLL(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return true }
        return isELF(path)
    }

    /// Rewrites games.json and config.json after a restore. Returns prefixes that still need wineboot.
    @discardableResult
    public static func apply(
        paths: FaugusPaths,
        macUserName: String = NSUserName(),
        runner: InstalledRunner? = nil
    ) throws -> Result {
        var outcome = Result()
        var configuration = try FaugusConfig.load(paths: paths)
        let defaultPrefix = configuration.string("default-prefix")
        if looksLikeLinuxPath(defaultPrefix) {
            configuration.setValue("default-prefix", rewriteLinuxPath(defaultPrefix, paths: paths))
            try configuration.save()
            outcome.importedLinux = true
        }

        let store = GamesStore(paths: paths)
        var games = try store.loadAll()
        var changed = false
        for index in games.indices {
            let before = games[index]
            let rewrittenPath = rewriteLinuxPath(before.path, paths: paths)
            let rewrittenPrefix = rewriteLinuxPath(before.prefix, paths: paths)
            if rewrittenPath != before.path || rewrittenPrefix != before.prefix {
                games[index].path = rewrittenPath
                games[index].prefix = rewrittenPrefix
                outcome.importedLinux = true
                changed = true
            }
            if isProtonRunner(before.runner) {
                games[index].runner = "Default"
                outcome.importedLinux = true
                changed = true
            }
            if isLinuxOnlyRunner(before.runner) {
                games[index].needsAttention = true
                outcome.importedLinux = true
                changed = true
            }
            if looksLikeLinuxPath(before.path) || looksLikeLinuxPath(before.prefix) {
                let pathExists = FileManager.default.fileExists(atPath: paths.expand(games[index].path))
                if !pathExists, !games[index].path.isEmpty {
                    games[index].needsAttention = true
                }
            }
        }
        if changed {
            try store.save(games: games)
        }

        let prefixes = Set(games.map { paths.expand($0.prefix) }.filter { !$0.isEmpty })
            .union([paths.expand(configuration.string("default-prefix")) + "/default"])
        for prefix in prefixes where FileManager.default.fileExists(atPath: prefix) {
            let touched = try fixPrefix(prefix, paths: paths, macUserName: macUserName, runner: runner)
            if touched {
                outcome.importedLinux = true
                outcome.prefixesNeedingWineboot.append(prefix)
            }
        }
        return outcome
    }

    /// Dangling symlink cleanup, steamuser rename, Proton DLL swap. Returns whether a Linux prefix was seen.
    public static func fixPrefix(
        _ prefix: String,
        paths: FaugusPaths,
        macUserName: String = NSUserName(),
        runner: InstalledRunner? = nil
    ) throws -> Bool {
        var touched = false
        touched = removeDanglingSymlinks(in: prefix) || touched
        touched = try renameSteamUser(in: prefix, to: macUserName) || touched
        if let runner {
            let system32 = prefix + "/drive_c/windows/system32"
            let hasLinuxDLL = LinuxFixup.protonGraphicsDLLs.contains {
                isELF(system32 + "/" + $0)
            }
            if hasLinuxDLL {
                try PrefixManager(paths: paths).replaceProtonGraphicsDLLs(prefix: prefix, runner: runner)
                touched = true
            }
        }
        return touched
    }

    public static func removeDanglingSymlinks(in root: String) -> Bool {
        let fileManager = FileManager.default
        guard let walker = fileManager.enumerator(atPath: root) else { return false }
        var removed = false
        for case let relativePath as String in walker {
            let fullPath = root + "/" + relativePath
            guard let target = try? fileManager.destinationOfSymbolicLink(atPath: fullPath) else { continue }
            let parent = URL(fileURLWithPath: fullPath).deletingLastPathComponent()
            let resolved = URL(fileURLWithPath: target, relativeTo: parent).path
            if !fileManager.fileExists(atPath: resolved) {
                try? fileManager.removeItem(atPath: fullPath)
                removed = true
            }
        }
        return removed
    }

    /// Rename `drive_c/users/steamuser` to the Mac short name and leave `steamuser` as a symlink.
    @discardableResult
    public static func renameSteamUser(in prefix: String, to macUserName: String) throws -> Bool {
        guard !macUserName.isEmpty, macUserName != "steamuser" else { return false }
        let users = prefix + "/drive_c/users"
        let steamPath = users + "/steamuser"
        let macPath = users + "/" + macUserName
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: steamPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        if fileManager.fileExists(atPath: macPath) {
            return false
        }
        do {
            try fileManager.moveItem(atPath: steamPath, toPath: macPath)
            try fileManager.createSymbolicLink(atPath: steamPath, withDestinationPath: macUserName)
            return true
        } catch {
            return false
        }
    }

    public static func isELF(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let magic = (try? handle.read(upToCount: 4)) ?? Data()
        return magic == Data([0x7F, 0x45, 0x4C, 0x46])
    }
}
