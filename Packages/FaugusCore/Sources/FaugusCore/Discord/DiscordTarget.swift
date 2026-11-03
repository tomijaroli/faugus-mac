import Foundation

/// Which Discord application to show and what to put in its activity.
public struct DiscordTarget: Equatable, Sendable {
    public var clientID: String
    /// Merged into the activity after `timestamps`; empty for a recognised game.
    public var activity: JSONObject

    public init(clientID: String, activity: JSONObject = JSONObject()) {
        self.clientID = clientID
        self.activity = activity
    }
}

/// Looks up an icon URL for the generic "playing <title>" activity (SteamGridDB, supplied by the app).
public typealias DiscordIconProvider = @Sendable () async -> String?

/// The game a presence session belongs to.
public struct DiscordGameIdentity: Equatable, Sendable {
    public var gameID: String
    public var title: String
    /// The game's configured executable path (Windows or POSIX); only its basename is used.
    public var executablePath: String

    public init(gameID: String, title: String, executablePath: String) {
        self.gameID = gameID
        self.title = title
        self.executablePath = executablePath
    }
}

/// `FaugusRun._discord_target`.
public actor DiscordTargetResolver {
    private let game: DiscordGameIdentity
    private let processProvider: @Sendable () -> [ProcessCandidate]
    private let otherRunningGameIDs: @Sendable () -> [String]
    private let iconProvider: DiscordIconProvider
    private let fallbackClientID: String
    private var isIconResolved = false
    private var resolvedIcon: String?

    /// - Parameters:
    ///   - processProvider: processes of the running game (name, `argv[0]`, working directory).
    ///   - otherRunningGameIDs: ids of the other games that are running; with any, no generic
    ///     activity is shown (it would be attributed to the wrong game).
    public init(
        game: DiscordGameIdentity,
        processProvider: @escaping @Sendable () -> [ProcessCandidate],
        otherRunningGameIDs: @escaping @Sendable () -> [String],
        iconProvider: @escaping DiscordIconProvider = { nil }
    ) {
        self.game = game
        self.processProvider = processProvider
        self.otherRunningGameIDs = otherRunningGameIDs
        self.iconProvider = iconProvider
        fallbackClientID = DiscordApplication.clientID
    }

    public func resolve(using index: DiscordDetectableIndex) async -> DiscordTarget? {
        if let match = Self.findRunningGame(in: processProvider(), index: index) {
            return DiscordTarget(clientID: match.applicationID)
        }
        if let applicationID = Self.findByTitle(game: game, index: index) {
            return DiscordTarget(clientID: applicationID)
        }
        if otherRunningGameIDs().contains(where: { $0 != game.gameID }) {
            return nil
        }
        var activity: JSONObject = ["details": .string(game.title), "status_display_type": 2]
        if let icon = await lookUpIconOnce(), !icon.isEmpty {
            activity["assets"] = ["large_image": .string(icon)]
        }
        return DiscordTarget(clientID: fallbackClientID, activity: activity)
    }

    /// The lookup may hit the network, so it runs once per session (upstream caches even a miss).
    private func lookUpIconOnce() async -> String? {
        if !isIconResolved {
            resolvedIcon = await iconProvider()
            isIconResolved = true
        }
        return resolvedIcon
    }

    // MARK: Matching

    struct RunningGameMatch: Equatable {
        var applicationID: String
        var applicationName: String
        var isLauncher: Bool
    }

    /// `discord_find_game`: a process whose name or `argv[0]` is a known executable (basename and
    /// path suffix); a real game beats a launcher.
    static func findRunningGame(in processes: [ProcessCandidate], index: DiscordDetectableIndex) -> RunningGameMatch? {
        var found: RunningGameMatch?
        for process in processes {
            var names = [process.name]
            if !process.firstArgument.isEmpty {
                names.append(process.firstArgument)
            }
            for name in names {
                let normalized = name.replacingOccurrences(of: "\\", with: "/").lowercased()
                let entries = index.entries(forBasename: DiscordDetectableIndex.basename(of: normalized))
                guard !entries.isEmpty else { continue }
                var paths = [normalized]
                if !normalized.contains("/"), let workingDirectory = process.workingDirectory {
                    paths.append(workingDirectory.lowercased() + "/" + normalized)
                }
                for entry in entries where paths.contains(where: { pathMatches($0, suffix: entry.executableName) }) {
                    if found == nil || (found?.isLauncher == true && !entry.isLauncher) {
                        found = RunningGameMatch(
                            applicationID: entry.applicationID, applicationName: entry.applicationName,
                            isLauncher: entry.isLauncher
                        )
                    }
                }
            }
        }
        return found
    }

    private static func pathMatches(_ path: String, suffix: String) -> Bool {
        path == suffix || path.hasSuffix("/" + suffix)
    }

    /// Falls back to the game's executable basename plus its title: non-launcher entries whose
    /// normalised application name contains or is contained in the normalised title; an exact
    /// name wins, then the lowest application id (Python's `min` over `(name != title, id)`).
    static func findByTitle(game: DiscordGameIdentity, index: DiscordDetectableIndex) -> String? {
        let title = alphanumericOnly(game.title)
        guard !title.isEmpty else { return nil }
        let executableName = game.executablePath.replacingOccurrences(of: "\\", with: "/").lowercased()
        let executableBasename = DiscordDetectableIndex.basename(of: executableName)
        var matches: [(isNotExact: Bool, applicationID: String)] = []
        for entry in index.entries(forBasename: executableBasename) where !entry.isLauncher {
            let applicationName = alphanumericOnly(entry.applicationName)
            let overlaps = applicationName.isEmpty || title.contains(applicationName)
                || applicationName.contains(title)
            if overlaps {
                matches.append((applicationName != title, entry.applicationID))
            }
        }
        let best = matches.min { first, second in
            if first.isNotExact != second.isNotExact {
                return !first.isNotExact
            }
            return first.applicationID < second.applicationID
        }
        return best?.applicationID
    }

    /// `re.sub(r"[^a-z0-9]", "", text.lower())`
    static func alphanumericOnly(_ text: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789".unicodeScalars)
        var result = String.UnicodeScalarView()
        result.append(contentsOf: text.lowercased().unicodeScalars.filter { allowed.contains($0) })
        return String(result)
    }
}
