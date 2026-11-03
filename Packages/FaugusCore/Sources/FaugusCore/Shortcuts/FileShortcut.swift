import Foundation

/// Port of upstream `shortcut.py` ("Create shortcut" for a file): a draft that becomes a stub
/// `.app` in both `~/Applications/Faugus` and `~/Desktop`, keyed by the formatted title.
///
/// The stub runs `Faugus --run <file> --in-prefix <prefix> --runner <runner> --log-id <id>`
/// plus `--pre-launch` / `--post-launch`, which is exactly what `LaunchMode.parse` reads for
/// `.runFile(target: .prefix(...))`. Nothing else is invented: the SDL flag, the No Sleep flag
/// and the `KEY=value` words of the launch arguments travel as environment variables the stub
/// exports (as upstream put them in front of its command).
///
/// Not carried: the game arguments and the non-`KEY=value` launch words (wrapper commands such
/// as `gamemoderun`), because the `--run` grammar has no place for them.
public struct FileShortcut: Equatable, Sendable {
    public var title: String
    /// The file to run (`.exe`, `.msi`, `.bat`, `.lnk`, `.reg`).
    public var executablePath: String
    public var prefixPath: String
    public var runnerName: String
    public var gameArguments = ""
    public var launchArguments = ""
    public var preLaunch = ""
    public var postLaunch = ""
    public var sdlEnabled = false
    public var noSleepEnabled = false
    /// A PNG the caller extracted from the file; `nil` or unreadable falls back to the Faugus icon.
    public var iconPath: String?

    public init(title: String, executablePath: String, prefixPath: String, runnerName: String) {
        self.title = title
        self.executablePath = executablePath
        self.prefixPath = prefixPath
        self.runnerName = runnerName
    }

    /// `format_title(title)`: the marker identifier, the log folder name and the key under
    /// which the shortcut is found again.
    public var shortcutID: String {
        GameID.format(title: title)
    }

    /// The Faugus argument list (without the executable) for this shortcut.
    public func faugusArguments(paths: FaugusPaths) -> [String] {
        var arguments = [
            "--run", paths.expand(executablePath),
            "--in-prefix", paths.expand(prefixPath),
            "--runner", runnerName,
            "--log-id", shortcutID,
        ]
        if !preLaunch.isEmpty {
            arguments += ["--pre-launch", preLaunch]
        }
        if !postLaunch.isEmpty {
            arguments += ["--post-launch", postLaunch]
        }
        return arguments
    }

    /// What the stub runs: `faugusExecutablePath` with `faugusArguments`, from the file's folder.
    public func launch(faugusExecutablePath: String, paths: FaugusPaths) throws -> ShortcutLaunch {
        let launchWords: [String]
        do {
            launchWords = try ShellWords.split(paths.expand(launchArguments))
        } catch {
            throw ShortcutError.invalidLaunchArguments("\(error)")
        }

        var environment: [ShortcutEnvironmentVariable] = []
        if sdlEnabled {
            environment.append(ShortcutEnvironmentVariable(name: "PROTON_PREFER_SDL", value: "1"))
        }
        if noSleepEnabled {
            environment.append(ShortcutEnvironmentVariable(name: "NO_SLEEP", value: "1"))
        }
        for (name, value) in ShellWords.extractEnvironment(from: launchWords).environment {
            environment.append(ShortcutEnvironmentVariable(name: name, value: value))
        }

        let fileDirectory = (paths.expand(executablePath) as NSString).deletingLastPathComponent
        return ShortcutLaunch(
            executablePath: faugusExecutablePath,
            arguments: faugusArguments(paths: paths),
            workingDirectory: fileDirectory.isEmpty ? nil : fileDirectory,
            environment: environment
        )
    }

    public func marker() -> ShortcutMarker {
        ShortcutMarker(gameID: shortcutID, kind: .file)
    }

    /// Installs the shortcut into both locations like upstream and returns the bundle paths.
    @discardableResult
    public func install(in library: ShortcutLibrary) throws -> [ShortcutLocation: String] {
        guard !shortcutID.isEmpty else { throw ShortcutError.missingIdentifier }
        return try library.install(
            marker: marker(),
            title: title,
            launch: launch(faugusExecutablePath: library.executablePath, paths: library.paths),
            locations: Set(ShortcutLocation.allCases),
            iconPath: iconPath
        )
    }

    /// Locations that hold a file shortcut for this title.
    public func existingLocations(in library: ShortcutLibrary) -> Set<ShortcutLocation> {
        library.existingLocations(gameID: shortcutID, kind: .file)
    }

    /// Deletes the file shortcut for this title (marker-gated).
    @discardableResult
    public func remove(from library: ShortcutLibrary) throws -> Set<ShortcutLocation> {
        try library.remove(marker: marker(), locations: Set(ShortcutLocation.allCases))
    }
}
