import Darwin
import Foundation

/// What the game supervisor needs from a Rich Presence session (lets tests substitute a fake).
public protocol DiscordPresenceControlling: Sendable {
    func start() async
    func stop() async
}

public struct DiscordPresenceConfiguration: Sendable {
    /// Directories searched for `discord-ipc-0` ... `discord-ipc-9`.
    public var socketDirectories: [String] = DiscordSocketLocator.defaultRuntimeDirectories()
    public var pollInterval: Duration = .seconds(5)
    public var connectionTimeout: TimeInterval = 3
    /// Reported to Discord as the activity's owner (`args.pid`).
    public var processID: Int32 = getpid()
    /// Shown as "elapsed" time in the activity.
    public var sessionStartDate = Date()

    public init() {}
}

/// Port of `FaugusRun._discord_start` / `_discord_close` / `_discord_stop`: every `pollInterval`
/// the target is recomputed; when it changes the old connection is closed and the new application
/// is announced with `SET_ACTIVITY`. Failures close the connection and are retried on the next poll
/// (upstream gives up on a target once it failed to connect; this also copes with Discord being
/// started after the game).
///
/// `start()` keeps the session alive until `stop()` is called.
public actor DiscordPresenceSession: DiscordPresenceControlling {
    private let loadIndex: @Sendable () async -> DiscordDetectableIndex
    private let resolver: DiscordTargetResolver
    private let configuration: DiscordPresenceConfiguration
    private var loopTask: Task<Void, Never>?
    private var connection: DiscordConnection?
    private var isStopped = false

    public init(
        loadIndex: @escaping @Sendable () async -> DiscordDetectableIndex,
        resolver: DiscordTargetResolver,
        configuration: DiscordPresenceConfiguration = DiscordPresenceConfiguration()
    ) {
        self.loadIndex = loadIndex
        self.resolver = resolver
        self.configuration = configuration
    }

    /// The real thing: the detectable index cached under `paths`, processes tagged with the
    /// game's `FAUGUSID`, and the running-games file.
    public static func live(
        paths: FaugusPaths, game: Game, iconProvider: @escaping DiscordIconProvider = { nil },
        configuration: DiscordPresenceConfiguration = DiscordPresenceConfiguration()
    ) -> DiscordPresenceSession {
        let gameID = game.gameID
        let runningGames = RunningGames(paths: paths)
        let resolver = DiscordTargetResolver(
            game: DiscordGameIdentity(gameID: gameID, title: game.title, executablePath: game.path),
            processProvider: { ProcessInspector.candidates(withEnvironment: "FAUGUSID", equalTo: gameID) },
            otherRunningGameIDs: {
                runningGames.load().filter { $0.key != gameID && ProcessSpawner.isAlive($0.value) }.map(\.key)
            },
            iconProvider: iconProvider
        )
        return DiscordPresenceSession(
            loadIndex: { await DiscordDetectableLoader(paths: paths).load() },
            resolver: resolver, configuration: configuration
        )
    }

    public func start() {
        guard loopTask == nil, !isStopped else { return }
        loopTask = Task { await runLoop() }
    }

    /// Cancels the loop and closes the connection. Safe to call repeatedly.
    public func stop() {
        isStopped = true
        loopTask?.cancel()
        loopTask = nil
        closeConnection()
    }

    // MARK: Loop

    private func runLoop() async {
        let index = await loadIndex()
        var currentTarget: DiscordTarget?
        while !Task.isCancelled, !isStopped {
            currentTarget = await synchronize(currentTarget: currentTarget, index: index)
            do {
                try await Task.sleep(for: configuration.pollInterval)
            } catch {
                break
            }
        }
        closeConnection()
    }

    /// One poll. Returns the target that is currently announced (`nil` when nothing is, so the
    /// next poll tries again).
    private func synchronize(currentTarget: DiscordTarget?, index: DiscordDetectableIndex) async -> DiscordTarget? {
        var announced = currentTarget
        if let connection, !connection.discardPendingReplies() {
            closeConnection()
            announced = nil
        }
        let target = await resolver.resolve(using: index)
        guard !Task.isCancelled, !isStopped else { return announced }
        guard target != announced else { return announced }

        closeConnection()
        guard let target else { return nil }
        let socketDirectories = configuration.socketDirectories
        let timeout = configuration.connectionTimeout
        let newConnection = await Self.runBlocking {
            DiscordConnection.connect(
                clientID: target.clientID, socketDirectories: socketDirectories, timeout: timeout
            )
        }
        guard let newConnection else { return nil }
        guard !Task.isCancelled, !isStopped else {
            newConnection.close()
            return nil
        }
        connection = newConnection
        let activityFrame = makeActivityFrame(for: target)
        do {
            try await Self.runBlockingThrowing { try newConnection.send(activityFrame) }
            return target
        } catch {
            closeConnection()
            return nil
        }
    }

    private func closeConnection() {
        connection?.close()
        connection = nil
    }

    func makeActivityFrame(for target: DiscordTarget) -> DiscordFrame {
        var activity = JSONObject()
        activity["timestamps"] = .object(["start": .int(Int64(configuration.sessionStartDate.timeIntervalSince1970))])
        for pair in target.activity.pairs {
            activity[pair.key] = pair.value
        }
        let arguments: JSONObject = ["pid": .int(Int64(configuration.processID)), "activity": .object(activity)]
        let payload: JSONObject = [
            "cmd": "SET_ACTIVITY",
            "args": .object(arguments),
            "nonce": .string(UUID().uuidString.lowercased()),
        ]
        return DiscordFrame(opcode: .frame, json: .object(payload))
    }

    /// Socket calls block for up to their timeout; keep them off the cooperative thread pool.
    private static func runBlockingThrowing<Output: Sendable>(
        _ work: @escaping @Sendable () throws -> Output
    ) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    private static func runBlocking<Output: Sendable>(_ work: @escaping @Sendable () -> Output) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work())
            }
        }
    }
}
