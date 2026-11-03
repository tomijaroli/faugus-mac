import Foundation

public enum LaunchEnvironment {
    /// Environment every Wine invocation shares: prefix, wine/wineserver, and a `PATH` that
    /// puts the runner first so helper scripts calling `wine` find the right one.
    public static func wineBase(
        prefix: String, runner: InstalledRunner, base: [String: String]
    ) -> [String: String] {
        var env = base
        env.removeValue(forKey: "VK_LOADER_LAYERS_DISABLE")
        env["WINEPREFIX"] = prefix
        env["WINE"] = runner.wineBinary
        env["WINESERVER"] = runner.wineserverBinary
        let path = base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = runner.wineRoot + "/bin:" + path
        return env
    }
}

/// Maps a file to the Wine command that runs it (plan section 3 "Launch path").
public enum LaunchSpec {
    public static func command(forPath path: String, wine: String) -> [String] {
        switch (path as NSString).pathExtension.lowercased() {
        case "msi": [wine, "msiexec", "/i", path]
        case "bat", "cmd": [wine, "cmd", "/c", path]
        case "lnk": [wine, "start", "/unix", path]
        case "reg": [wine, "regedit", path]
        default: [wine, path]
        }
    }
}

public enum LaunchError: Error, Equatable, CustomStringConvertible {
    case badArguments(String)
    case emptyPath
    public var description: String {
        switch self {
        case let .badArguments(m): "Cannot parse launch arguments: \(m)"
        case .emptyPath: "The game has no executable path"
        }
    }
}

/// Everything needed to spawn a game, computed without side effects.
public struct LaunchPlan: Sendable {
    public var argv: [String]
    public var environment: [String: String]
    public var workingDirectory: String
    public var prefix: String
    public var gameID: String
    public var graphics: GraphicsPlan
    public var splashIcon: String?
    public var noSleep: Bool
    public var discordRPC: Bool
    public var logsEnabled: Bool
    public var logDirectory: String

    public var executable: String {
        argv[0]
    }

    public var arguments: [String] {
        Array(argv.dropFirst())
    }

    /// Printed to `faugus.log` the way upstream prints its "UMU-LAUNCHER COMMAND".
    public var commandDescription: String {
        ShellWords.join(argv)
    }
}

public enum LaunchPlanner {
    public static let logsWineDebug = "+timestamp,+pid,+tid,+seh,+debugstr,+loaddll"

    /// Port of `build_launch_command` + `extract_env_from_message` + the `envar.json` merge.
    ///
    /// Precedence of environment values, lowest to highest (same as upstream, where the global
    /// file is applied last):
    /// process env, Faugus computed, the game's `launch_arguments`, global `envar.json`.
    public static func plan(
        game: Game,
        config: FaugusConfig,
        runner: InstalledRunner,
        paths: FaugusPaths,
        logs: Bool,
        graphics: GraphicsPlan,
        globalEnvironment: [(String, String)] = [],
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> LaunchPlan {
        let defaultPrefix = paths.expand(config.string("default-prefix"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        var prefix = paths.expand(game.prefix)
        if prefix.isEmpty {
            prefix = (defaultPrefix.isEmpty ? paths.prefixesDir : defaultPrefix) + "/default"
        }

        var exePath = paths.expand(game.path)
        if game.addAppEnabled, !game.addAppBat.isEmpty {
            exePath = paths.expand(game.addAppBat)
        }
        if exePath.isEmpty {
            throw LaunchError.emptyPath
        }

        let launchWords: [String]
        let gameWords: [String]
        do {
            launchWords = try ShellWords.split(paths.expand(game.launchArguments))
            gameWords = try ShellWords.split(paths.expand(game.gameArguments))
        } catch {
            throw LaunchError.badArguments("\(error)")
        }
        let (userEnv, wrapper) = ShellWords.extractEnvironment(from: launchWords)

        // Faugus computed layer.
        var env = LaunchEnvironment.wineBase(prefix: prefix, runner: runner, base: baseEnvironment)
        let logDir = paths.gameLogsDir(gameID: game.gameID.isEmpty ? "default" : game.gameID)
        if !game.gameID.isEmpty {
            env["FAUGUSID"] = game.gameID
        }
        env["WINEDEBUG"] = logs ? logsWineDebug : "-all"
        if logs {
            env["DXVK_LOG_LEVEL"] = "info"
            env["DXVK_LOG_PATH"] = logDir
            env["MVK_CONFIG_LOG_LEVEL"] = "2"
        }
        for (k, v) in graphics.environment {
            env[k] = v
        }

        // WINEDLLOVERRIDES: winemenubuilder off + graphics, merged with whatever the user set.
        var overrides: [(dll: String, mode: String)] = [("winemenubuilder.exe", "d")] + graphics.dllOverrides
        func applyUser(_ key: String, _ value: String) {
            if key == "WINEDLLOVERRIDES" {
                overrides = DLLOverrides.merge(base: overrides, overriding: DLLOverrides.parse(value))
            } else {
                env[key] = value
            }
        }
        for (k, v) in userEnv {
            applyUser(k, v)
        }
        for (k, v) in globalEnvironment {
            applyUser(k, v)
        }
        env["WINEDLLOVERRIDES"] = DLLOverrides.serialize(overrides)

        let argv = wrapper + LaunchSpec.command(forPath: exePath, wine: runner.wineBinary) + gameWords

        let workDir = (exePath as NSString).deletingLastPathComponent
        var isDir: ObjCBool = false
        let cwd = FileManager.default.fileExists(atPath: workDir, isDirectory: &isDir) && isDir.boolValue
            ? workDir : prefix

        return LaunchPlan(
            argv: argv, environment: env, workingDirectory: cwd, prefix: prefix, gameID: game.gameID,
            graphics: graphics, splashIcon: game.icon.isEmpty ? nil : game.icon,
            noSleep: game.noSleep, discordRPC: game.discordRPC, logsEnabled: logs, logDirectory: logDir
        )
    }

    /// `load_env_from_file`: `envar.json` is a JSON list of `KEY=VALUE` lines.
    public static func loadGlobalEnvironment(paths: FaugusPaths) -> [(String, String)] {
        let json = JSONFile.load(paths.envarFile, default: .array([]))
        var out: [(String, String)] = []
        for line in (json.arrayValue ?? []).compactMap(\.stringValue) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, let eq = t.firstIndex(of: "=") else { continue }
            let k = t[..<eq].trimmingCharacters(in: .whitespaces)
            let v = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            out.append((k, v))
        }
        return out
    }
}
