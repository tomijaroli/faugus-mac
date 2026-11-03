import Foundation

/// Where a shortcut bundle lives. Upstream's `appmenu` and `desktop` `.desktop` files.
public enum ShortcutLocation: String, CaseIterable, Hashable, Sendable {
    /// `~/Applications/Faugus` (`FaugusPaths.userApplicationsShortcutsDirectory`).
    case applicationsMenu
    /// `~/Desktop` (`FaugusPaths.desktopDirectory`).
    case desktop
}

/// What a shortcut starts: a saved game (`--game <id>`) or a file run in a prefix (`--run <spec>`).
public enum ShortcutKind: String, Sendable {
    case game
    case file
}

/// The `faugus-shortcut.json` file inside every bundle Faugus writes. Shortcuts are found,
/// updated and removed by this marker, never by file name, so a renamed game keeps its shortcut
/// and a foreign `.app` is never touched.
public struct ShortcutMarker: Equatable, Sendable {
    public var gameID: String
    public var kind: ShortcutKind

    public init(gameID: String, kind: ShortcutKind) {
        self.gameID = gameID
        self.kind = kind
    }
}

/// An environment variable the stub script exports before starting Faugus.
public struct ShortcutEnvironmentVariable: Equatable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// The data behind a bundle's `launch` script: run `executablePath` with `arguments`, from
/// `workingDirectory` when that folder exists at launch time.
public struct ShortcutLaunch: Equatable, Sendable {
    public var executablePath: String
    public var arguments: [String]
    public var workingDirectory: String?
    public var environment: [ShortcutEnvironmentVariable]

    public init(
        executablePath: String,
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [ShortcutEnvironmentVariable] = []
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

public enum ShortcutError: Error, Equatable, CustomStringConvertible {
    /// The game or file shortcut has no usable identifier (empty `gameid` or a title without word characters).
    case missingIdentifier
    case invalidLaunchArguments(String)
    /// Neither the game's icon nor the fallback icon could be decoded.
    case iconUnavailable
    /// A bundle without the Faugus marker file is in the way; it is never replaced or deleted.
    case foreignBundleInTheWay(String)
    case writeFailed(path: String, reason: String)

    public var description: String {
        switch self {
        case .missingIdentifier: "The shortcut has no identifier"
        case let .invalidLaunchArguments(message): "Cannot parse launch arguments: \(message)"
        case .iconUnavailable: "The shortcut icon cannot be read"
        case let .foreignBundleInTheWay(path): "\(path) is not a Faugus shortcut and was left alone"
        case let .writeFailed(path, reason): "Cannot write the shortcut at \(path): \(reason)"
        }
    }
}
