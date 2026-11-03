import Foundation

/// Port of `faugus/path_manager.py`, mapping the XDG layout onto macOS conventions.
///
/// | Upstream (XDG)                          | Mac port                                         |
/// | --------------------------------------- | ------------------------------------------------ |
/// | `~/.config/faugus-launcher`             | `~/Library/Application Support/Faugus/config`    |
/// | `~/.local/share/faugus-launcher`        | `~/Library/Application Support/Faugus/data`      |
/// | `~/.local/state/faugus-launcher`        | `~/Library/Application Support/Faugus/state`     |
/// | `.../logs`                              | `~/Library/Logs/Faugus`                          |
/// | `.../faugus_temp`                       | `~/Library/Caches/Faugus/tmp`                    |
/// | `~/Faugus`                              | `~/Faugus` (unchanged)                           |
///
/// All locations are derived from a single `home` so tests (and `FAUGUS_HOME`) can sandbox
/// everything.
public struct FaugusPaths: Equatable, Sendable {
    public let home: String

    public init(home: String) {
        self.home = (home as NSString).standardizingPath
    }

    /// The real user's home, or `FAUGUS_HOME` when set (development, integration tests).
    public static var live: FaugusPaths {
        if let override = ProcessInfo.processInfo.environment["FAUGUS_HOME"], !override.isEmpty {
            return FaugusPaths(home: override)
        }
        return FaugusPaths(home: NSHomeDirectory())
    }

    private func h(_ parts: String...) -> String {
        parts.reduce(home) { ($0 as NSString).appendingPathComponent($1) }
    }

    // MARK: Roots

    public var appSupport: String {
        h("Library", "Application Support", "Faugus")
    }

    public var configDirectory: String {
        appSupport + "/config"
    }

    public var dataDirectory: String {
        appSupport + "/data"
    }

    public var stateDirectory: String {
        appSupport + "/state"
    }

    public var runnersDirectory: String {
        appSupport + "/runners"
    }

    public var componentsDirectory: String {
        appSupport + "/components"
    }

    public var dxvkMacOSDir: String {
        componentsDirectory + "/dxvk-macos"
    }

    public var winetricksDirectory: String {
        componentsDirectory + "/winetricks"
    }

    public var cachesDirectory: String {
        h("Library", "Caches", "Faugus")
    }

    public var tempDirectory: String {
        cachesDirectory + "/tmp"
    }

    public var logsDirectory: String {
        h("Library", "Logs", "Faugus")
    }

    /// `PREFIXES_DIR`: default parent of per-game prefixes (kept at `~/Faugus` like upstream).
    public var prefixesDirectory: String {
        h("Faugus")
    }

    public var defaultPrefix: String {
        prefixesDirectory + "/default"
    }

    public var userApplicationsShortcutsDirectory: String {
        h("Applications", "Faugus")
    }

    public var desktopDirectory: String {
        h("Desktop")
    }

    // MARK: Config dir files

    public var configFile: String {
        configDirectory + "/config.json"
    }

    public var environmentVariablesFile: String {
        configDirectory + "/envar.json"
    }

    // MARK: Data dir files and folders

    public var gamesJSON: String {
        dataDirectory + "/games.json"
    }

    public var presetsFile: String {
        dataDirectory + "/presets.json"
    }

    public var categoriesFile: String {
        dataDirectory + "/categories.json"
    }

    public var customOrderFile: String {
        dataDirectory + "/custom-order.json"
    }

    public var coversDirectory: String {
        dataDirectory + "/covers"
    }

    public var bannersDirectory: String {
        dataDirectory + "/banners"
    }

    public var iconsDirectory: String {
        dataDirectory + "/icons"
    }

    public var shortcutIconsDirectory: String {
        dataDirectory + "/icons-nolauncher"
    }

    public var gamesBackupDirectory: String {
        dataDirectory + "/games-backup"
    }

    // MARK: State dir files

    public var latestGamesFile: String {
        stateDirectory + "/latest-games.json"
    }

    public var recentRunFilesFile: String {
        stateDirectory + "/recent-run-files.json"
    }

    public var runningGamesFile: String {
        stateDirectory + "/running-games.json"
    }

    public var fileChooserFoldersFile: String {
        stateDirectory + "/filechooser_folders.json"
    }

    public func stopFile(gameID: String) -> String {
        stateDirectory + "/stop-" + gameID
    }

    public var launcherLockFile: String {
        stateDirectory + "/launcher.lock"
    }

    public var backupLockFile: String {
        stateDirectory + "/backup.lock"
    }

    public var backupCancelFile: String {
        stateDirectory + "/backup.cancel"
    }

    public var backupDaemonTokenFile: String {
        stateDirectory + "/daemon.token"
    }

    public var backupStagingDirectory: String {
        tempDirectory + "/temp-backup"
    }

    public var restoreStagingDirectory: String {
        tempDirectory + "/temp-restore"
    }

    /// Upstream's default when `backup-dest-dir` is empty: `~/Faugus Backup`.
    public var defaultBackupDestination: String {
        h("Faugus Backup")
    }

    public func gameLogsDirectory(gameID: String) -> String {
        logsDirectory + "/" + gameID
    }

    // MARK: Helpers

    /// `expand_path`: `~` and `$VARS`.
    public func expand(_ value: String) -> String {
        guard !value.isEmpty else { return value }
        var expanded = value
        if expanded == "~" {
            expanded = home
        } else if expanded.hasPrefix("~/") {
            expanded = home + String(expanded.dropFirst(1))
        }
        return expandEnvironmentVariables(expanded)
    }

    private func expandEnvironmentVariables(_ text: String) -> String {
        guard text.contains("$") else { return text }
        let environment = ProcessInfo.processInfo.environment
        var out = ""
        var position = text.startIndex
        while position < text.endIndex {
            let character = text[position]
            guard character == "$" else { out.append(character)
                position = text.index(after: position)
                continue
            }
            var lookahead = text.index(after: position)
            var name = ""
            var braced = false
            if lookahead < text.endIndex, text[lookahead] == "{" {
                braced = true
                lookahead = text.index(after: lookahead)
            }
            while lookahead < text.endIndex,
                  text[lookahead].isLetter || text[lookahead].isNumber || text[lookahead] == "_",
                  text[lookahead].isASCII
            {
                name.append(text[lookahead])
                lookahead = text.index(after: lookahead)
            }
            if braced {
                if lookahead < text.endIndex, text[lookahead] == "}", !name.isEmpty {
                    lookahead = text.index(after: lookahead)
                } else {
                    name = ""
                }
            }
            if !name.isEmpty, let variableValue = environment[name] {
                out += variableValue
                position = lookahead
            } else {
                // Python's expandvars leaves unknown variables untouched.
                out.append(character)
                position = text.index(after: position)
            }
        }
        return out
    }

    public func ensureDirectories() throws {
        let fileManager = FileManager.default
        let directories = [
            configDirectory, dataDirectory, stateDirectory, runnersDirectory,
            componentsDirectory, tempDirectory, logsDirectory,
        ]
        for directory in directories {
            try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
    }
}
