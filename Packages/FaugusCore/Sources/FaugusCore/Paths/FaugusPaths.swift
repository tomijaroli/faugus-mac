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

    public var configDir: String {
        appSupport + "/config"
    }

    public var dataDir: String {
        appSupport + "/data"
    }

    public var stateDir: String {
        appSupport + "/state"
    }

    public var runnersDir: String {
        appSupport + "/runners"
    }

    public var componentsDir: String {
        appSupport + "/components"
    }

    public var dxvkMacOSDir: String {
        componentsDir + "/dxvk-macos"
    }

    public var winetricksDir: String {
        componentsDir + "/winetricks"
    }

    public var cachesDir: String {
        h("Library", "Caches", "Faugus")
    }

    public var tempDir: String {
        cachesDir + "/tmp"
    }

    public var logsDir: String {
        h("Library", "Logs", "Faugus")
    }

    /// `PREFIXES_DIR`: default parent of per-game prefixes (kept at `~/Faugus` like upstream).
    public var prefixesDir: String {
        h("Faugus")
    }

    public var defaultPrefix: String {
        prefixesDir + "/default"
    }

    public var userApplicationsShortcutsDir: String {
        h("Applications", "Faugus")
    }

    public var desktopDir: String {
        h("Desktop")
    }

    // MARK: Config dir files

    public var configFile: String {
        configDir + "/config.json"
    }

    public var envarFile: String {
        configDir + "/envar.json"
    }

    // MARK: Data dir files and folders

    public var gamesJSON: String {
        dataDir + "/games.json"
    }

    public var presetsFile: String {
        dataDir + "/presets.json"
    }

    public var categoriesFile: String {
        dataDir + "/categories.json"
    }

    public var customOrderFile: String {
        dataDir + "/custom-order.json"
    }

    public var coversDir: String {
        dataDir + "/covers"
    }

    public var bannersDir: String {
        dataDir + "/banners"
    }

    public var iconsDir: String {
        dataDir + "/icons"
    }

    public var shortcutIconsDir: String {
        dataDir + "/icons-nolauncher"
    }

    public var gamesBackupDir: String {
        dataDir + "/games-backup"
    }

    // MARK: State dir files

    public var latestGamesFile: String {
        stateDir + "/latest-games.json"
    }

    public var recentRunFilesFile: String {
        stateDir + "/recent-run-files.json"
    }

    public var runningGamesFile: String {
        stateDir + "/running-games.json"
    }

    public var fileChooserFoldersFile: String {
        stateDir + "/filechooser_folders.json"
    }

    public func stopFile(gameID: String) -> String {
        stateDir + "/stop-" + gameID
    }

    public func gameLogsDir(gameID: String) -> String {
        logsDir + "/" + gameID
    }

    // MARK: Helpers

    /// `expand_path`: `~` and `$VARS`.
    public func expand(_ value: String) -> String {
        guard !value.isEmpty else { return value }
        var s = value
        if s == "~" {
            s = home
        } else if s.hasPrefix("~/") {
            s = home + String(s.dropFirst(1))
        }
        return expandEnvironmentVariables(s)
    }

    private func expandEnvironmentVariables(_ s: String) -> String {
        guard s.contains("$") else { return s }
        let env = ProcessInfo.processInfo.environment
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            guard c == "$" else { out.append(c)
                i = s.index(after: i)
                continue
            }
            var j = s.index(after: i)
            var name = ""
            var braced = false
            if j < s.endIndex, s[j] == "{" {
                braced = true
                j = s.index(after: j)
            }
            while j < s.endIndex, s[j].isLetter || s[j].isNumber || s[j] == "_", s[j].isASCII {
                name.append(s[j])
                j = s.index(after: j)
            }
            if braced {
                if j < s.endIndex, s[j] == "}", !name.isEmpty {
                    j = s.index(after: j)
                } else {
                    name = ""
                }
            }
            if !name.isEmpty, let v = env[name] {
                out += v
                i = j
            } else {
                // Python's expandvars leaves unknown variables untouched.
                out.append(c)
                i = s.index(after: i)
            }
        }
        return out
    }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [configDir, dataDir, stateDir, runnersDir, componentsDir, tempDir, logsDir] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }
}
