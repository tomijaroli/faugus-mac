import Foundation

public enum LaunchEnvironment {
    /// Environment every Wine invocation shares: prefix, wine/wineserver, and a `PATH` that
    /// puts the runner first so helper scripts calling `wine` find the right one.
    public static func wineBase(
        prefix: String, runner: InstalledRunner, base: [String: String]
    ) -> [String: String] {
        var environment = base
        environment.removeValue(forKey: "VK_LOADER_LAYERS_DISABLE")
        environment["WINEPREFIX"] = prefix
        environment["WINE"] = runner.wineBinary
        environment["WINESERVER"] = runner.wineserverBinary
        let path = base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = runner.wineRoot + "/bin:" + path
        return environment
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
        case let .badArguments(message): "Cannot parse launch arguments: \(message)"
        case .emptyPath: "The game has no executable path"
        }
    }
}

/// Everything needed to spawn a game, computed without side effects.
public struct LaunchPlan: Sendable {
    public var commandLine: [String]
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
        commandLine[0]
    }

    public var arguments: [String] {
        Array(commandLine.dropFirst())
    }

    /// Printed to `faugus.log` the way upstream prints its "UMU-LAUNCHER COMMAND".
    public var commandDescription: String {
        ShellWords.join(commandLine)
    }
}

public enum LaunchPlanner {
    public static let logsWineDebug = "+timestamp,+pid,+tid,+seh,+debugstr,+loaddll"

    /// Port of `build_launch_command` + `extract_env_from_message` + the `environmentVariable.json` merge.
    ///
    /// Precedence of environment values, lowest to highest (same as upstream, where the global
    /// file is applied last):
    /// process env, Faugus computed, the game's `launch_arguments`, global `environmentVariable.json`.
    public static func plan( // swiftlint:disable:this function_parameter_count
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
            prefix = (defaultPrefix.isEmpty ? paths.prefixesDirectory : defaultPrefix) + "/default"
        }

        var executablePath = paths.expand(game.path)
        if game.addAppEnabled, !game.addAppBat.isEmpty {
            executablePath = paths.expand(game.addAppBat)
        }
        if executablePath.isEmpty {
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
        let (userEnvironment, wrapper) = ShellWords.extractEnvironment(from: launchWords)

        // Faugus computed layer.
        var environment = LaunchEnvironment.wineBase(prefix: prefix, runner: runner, base: baseEnvironment)
        let logDirectory = paths.gameLogsDirectory(gameID: game.gameID.isEmpty ? "default" : game.gameID)
        if !game.gameID.isEmpty {
            environment["FAUGUSID"] = game.gameID
        }
        environment["WINEDEBUG"] = logs ? logsWineDebug : "-all"
        if logs {
            environment["DXVK_LOG_LEVEL"] = "info"
            environment["DXVK_LOG_PATH"] = logDirectory
            environment["MVK_CONFIG_LOG_LEVEL"] = "2"
        }
        for (key, value) in graphics.environment {
            environment[key] = value
        }

        // WINEDLLOVERRIDES: winemenubuilder off + graphics, merged with whatever the user set.
        var overrides: [(dll: String, mode: String)] = [("winemenubuilder.exe", "d")] + graphics.dllOverrides
        func applyUser(_ key: String, _ value: String) {
            if key == "WINEDLLOVERRIDES" {
                overrides = DLLOverrides.merge(base: overrides, overriding: DLLOverrides.parse(value))
            } else {
                environment[key] = value
            }
        }
        for (key, value) in userEnvironment {
            applyUser(key, value)
        }
        for (key, value) in globalEnvironment {
            applyUser(key, value)
        }
        environment["WINEDLLOVERRIDES"] = DLLOverrides.serialize(overrides)

        let commandLine = wrapper + LaunchSpec.command(forPath: executablePath, wine: runner.wineBinary) + gameWords

        let workDirectory = (executablePath as NSString).deletingLastPathComponent
        var isDirectory: ObjCBool = false
        let launchDirectory = FileManager.default
            .fileExists(atPath: workDirectory, isDirectory: &isDirectory) && isDirectory.boolValue
            ? workDirectory : prefix

        return LaunchPlan(
            commandLine: commandLine, environment: environment, workingDirectory: launchDirectory, prefix: prefix,
            gameID: game.gameID,
            graphics: graphics, splashIcon: game.icon.isEmpty ? nil : game.icon,
            noSleep: game.noSleep, discordRPC: game.discordRPC, logsEnabled: logs, logDirectory: logDirectory
        )
    }

    /// `load_env_from_file`: `environmentVariable.json` is a JSON list of `KEY=VALUE` lines.
    public static func loadGlobalEnvironment(paths: FaugusPaths) -> [(String, String)] {
        let json = JSONFile.load(paths.environmentVariablesFile, default: .array([]))
        var entries: [(String, String)] = []
        for line in (json.arrayValue ?? []).compactMap(\.stringValue) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty, let equalsIndex = trimmedLine.firstIndex(of: "=") else { continue }
            let key = trimmedLine[..<equalsIndex].trimmingCharacters(in: .whitespaces)
            let value = trimmedLine[trimmedLine.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
            entries.append((key, value))
        }
        return entries
    }
}
