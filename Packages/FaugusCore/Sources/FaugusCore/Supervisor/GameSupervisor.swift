import Darwin
import Foundation

public enum SupervisorEvent: Equatable, Sendable {
    case preparing(title: String)
    case checkingRosetta
    case downloadingRunner(name: String, progress: Double)
    case downloadingComponent(name: String, progress: Double)
    case creatingPrefix
    case starting(command: String)
    case running(pid: Int32)
    case stopping
    case exited(status: Int32, playtimeSeconds: Int)
    case failed(SupervisorFailure)
}

public enum SupervisorFailure: Equatable, Sendable, CustomStringConvertible {
    case gameNotFound(String)
    case rosettaMissing
    case runnerNotFound(String)
    case runnerInstallFailed(String)
    case componentInstallFailed(String)
    case prefixFailed(String)
    case launchFailed(String)

    public var description: String {
        switch self {
        case let .gameNotFound(id): "Game \"\(id)\" was not found in games.json"
        case .rosettaMissing: "Rosetta 2 is required to run Wine"
        case let .runnerNotFound(n): "\(n) was not found"
        case let .runnerInstallFailed(m): "Could not install the Wine runner: \(m)"
        case let .componentInstallFailed(m): "Could not install DXVK-macOS: \(m)"
        case let .prefixFailed(m): m
        case let .launchFailed(m): m
        }
    }
}

public struct SupervisorOptions: Sendable {
    public var logs = false
    /// `--run <file>`: run this file in the game's prefix (installer, `.reg`, helper tool)
    /// instead of the game. No playtime, no running state, no hooks, no `FAUGUSID` tag.
    public var runFile: String?
    /// With `runFile`: run in this prefix/runner instead of a saved game's (Add Game dialog).
    public var adhocGame: Game?
    public var preLaunch: String?
    public var postLaunch: String?
    /// Called when Rosetta is missing; return `true` once it is installed.
    public var ensureRosetta: @Sendable () async -> Bool = { await Rosetta.isInstalled() }
    /// Upstream honours `FAUGUS_DISABLE_UPDATES` and the `automatic-updates` setting.
    public var allowDownloads = true
    public var checkForRunnerUpdates = true
    public var pollInterval: Duration = .milliseconds(250)
    /// Seconds between playtime saves (wall clock, independent of `pollInterval`).
    public var playtimeSaveInterval: Double = 30
    public var stopGrace: Duration = .seconds(3)
    public var baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    /// Opens a `steam://` URL (Steam-type games). Returns false when it could not be started.
    public var openSteamURL: @Sendable (String) -> Bool = { url in
        (try? ProcessSpawner.spawn(
            argv: ["/usr/bin/open", url],
            options: .init(environment: ["PATH": "/usr/bin:/bin"], newSession: true)
        )) != nil
    }

    /// How long the splash stays up after handing a game to Steam (upstream: 5 s).
    public var steamSplashDuration: Duration = .seconds(5)
    public var feed: @Sendable () async throws -> [RemoteRunner] = { try await GcenxFeed.fetchAll() }

    public init() {}
}

/// Runs one game from start to finish: the runner process's brain (plan section 5).
public actor GameSupervisor {
    public let paths: FaugusPaths
    public let gameID: String
    private let options: SupervisorOptions
    private let sink: @Sendable (SupervisorEvent) -> Void
    private let log: FaugusLog
    private let running: RunningGames

    private var gamePID: pid_t = 0
    private var gameExit: Int32?
    private var serverWaitDone = false
    private var stopRequested = false
    private var startedAt = Date()

    public init(
        paths: FaugusPaths, gameID: String, options: SupervisorOptions = SupervisorOptions(),
        sink: @escaping @Sendable (SupervisorEvent) -> Void = { _ in }
    ) {
        self.paths = paths
        self.gameID = gameID
        self.options = options
        self.sink = sink
        log = FaugusLog(path: paths.gameLogsDirectory(gameID: gameID) + "/faugus.log")
        running = RunningGames(paths: paths)
    }

    private func emit(_ e: SupervisorEvent) {
        sink(e)
        switch e {
        case let .failed(f): log.write("FAILED: \(f)")
        case let .starting(c): log.write("command: \(c)")
        case let .exited(s, p): log.write("exited status=\(s) playtime=\(p)s")
        default: break
        }
    }

    // MARK: Run

    @discardableResult
    public func run() async -> SupervisorFailure? {
        do {
            let failure = try await runInner()
            if let failure {
                emit(.failed(failure))
            }
            return failure
        } catch {
            let f = SupervisorFailure.launchFailed("\(error)")
            emit(.failed(f))
            return f
        }
    }

    // The launch sequence, step by step as numbered inside; one function keeps the order obvious.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func runInner() async throws -> SupervisorFailure? {
        if options.logs {
            log.truncate()
        }
        let config = try FaugusConfig.load(paths: paths)

        // 1. Game
        let game: Game
        if let adhoc = options.adhocGame, options.runFile != nil {
            game = adhoc
        } else {
            let games = try GamesStore(paths: paths).loadAll()
            guard let found = games.first(where: { $0.gameID == gameID }) else { return .gameNotFound(gameID) }
            game = found
        }
        if game.runner == "Steam", options.runFile == nil {
            return await runSteamGame(game)
        }
        let isFileRun = options.runFile != nil
        emit(.preparing(title: game.title))
        log.write(isFileRun ? "running \(options.runFile ?? "") in the prefix of \(game.title) (\(gameID))"
            : "starting \(game.title) (\(gameID))")

        // 2. Rosetta
        emit(.checkingRosetta)
        if await !(Rosetta.isInstalled()) {
            guard await options.ensureRosetta() else { return .rosettaMissing }
        }

        // 3. Runner
        let (runner, runnerFailure) = await resolveRunner(game: game, config: config)
        guard let runner else { return runnerFailure }

        // 4. Graphics decision, DXVK component
        let request = GraphicsPlan.effectiveRequest(game: game, config: config)
        let dxvk = DXVKComponent(paths: paths)
        var graphics = GraphicsPlan.resolve(requested: request, capabilities: runner.capabilities)
        if graphics.backend == .dxvk, !dxvk.isInstalled {
            if options.allowDownloads {
                do {
                    try await dxvk.install { [sink] p in sink(.downloadingComponent(name: "DXVK-macOS", progress: p)) }
                } catch {
                    graphics = GraphicsPlan.resolve(requested: .wined3d, capabilities: runner.capabilities)
                    log.write("DXVK-macOS unavailable (\(error)); using wined3d")
                }
            } else {
                graphics = GraphicsPlan.resolve(requested: .wined3d, capabilities: runner.capabilities)
            }
        }
        for note in graphics.notes {
            log.write(note)
        }

        // 5. Plan (also gives us the prefix path)
        var planned = game
        if let file = options.runFile {
            planned.path = file
            planned.gameArguments = ""
            planned.addAppEnabled = false
        }
        var plan: LaunchPlan
        do {
            plan = try LaunchPlanner.plan(
                game: planned, config: config, runner: runner, paths: paths, logs: options.logs,
                graphics: graphics, globalEnvironment: LaunchPlanner.loadGlobalEnvironment(paths: paths),
                baseEnvironment: options.baseEnvironment
            )
        } catch {
            return .launchFailed("\(error)")
        }
        if isFileRun {
            // Not the game: untagged, and started from the game's folder like upstream.
            plan.environment.removeValue(forKey: "FAUGUSID")
            let gameDirectory = (paths.expand(game.path) as NSString).deletingLastPathComponent
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: gameDirectory, isDirectory: &isDirectory), isDirectory.boolValue {
                plan.workingDirectory = gameDirectory
            }
        }

        // 6. Prefix
        let prefixes = PrefixManager(paths: paths)
        if !prefixes.isCreated(prefix: plan.prefix) {
            emit(.creatingPrefix)
            do {
                try await prefixes.create(prefix: plan.prefix, runner: runner, baseEnvironment: options.baseEnvironment)
            } catch {
                return .prefixFailed("\(error)")
            }
        }
        do { try prefixes.applyGraphics(graphics, prefix: plan.prefix, runner: runner, dxvk: dxvk) }
        catch { log.write("could not apply graphics backend: \(error)") }

        // 7. Pre-launch hook (fire and forget, like upstream)
        let pre = options.preLaunch ?? game.preLaunch
        if !isFileRun, !pre.isEmpty {
            spawnHook(pre, env: plan.environment)
        }

        // 8. Spawn
        log.writeSection(
            "ENVIRONMENT",
            plan.environment
                .filter {
                    Self.interestingKeys.contains($0.key) || $0.key.hasPrefix("DXVK") || $0.key.hasPrefix("MVK") || $0
                        .key
                        .hasPrefix("WINE")
                }
                .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        )
        log.write("graphics: requested=\(graphics.requested.rawValue) backend=\(graphics.backend.rawValue)")
        emit(.starting(command: plan.commandDescription))

        let gameBaseline = PlaytimeStore(paths: paths).gamePlaytime(gameID: gameID)
        let totalBaseline = config.int("playtime")
        if !isFileRun {
            _ = try? running.consumeStopRequest(gameID: gameID)
        }

        let pid: pid_t
        do {
            pid = try ProcessSpawner.spawn(
                argv: plan.argv,
                options: .init(
                    workingDirectory: plan.workingDirectory, environment: plan.environment,
                    outputFile: options.logs ? plan.logDirectory + "/wine.log" : nil, newSession: true
                )
            )
        } catch {
            return .launchFailed("\(error)")
        }
        gamePID = pid
        startedAt = Date()
        if !isFileRun {
            try? running.mark(gameID: gameID, pid: getpid())
        }
        emit(.running(pid: pid))

        let sleepAssertion = plan.noSleep && !isFileRun ? SleepInhibitor(reason: "Game is running") : nil
        defer { sleepAssertion?.release() }

        Task { [weak self] in
            let status = await ProcessSpawner.waitForExit(pid: pid)
            await self?.gameProcessExited(status)
        }

        // 9. Supervise
        var lastSave = Date()
        var serverStarted = false
        while !serverWaitDone {
            try? await Task.sleep(for: options.pollInterval)

            if !isFileRun, !stopRequested, running.consumeStopRequest(gameID: gameID) {
                stopRequested = true
                emit(.stopping)
                Task { [weak self] in
                    await self?.terminate(runner: runner, prefix: plan.prefix, env: plan.environment)
                }
            }

            if gameExit != nil, !serverStarted {
                serverStarted = true
                waitForWineserver(runner: runner, env: plan.environment)
            }

            if !isFileRun, Date().timeIntervalSince(lastSave) >= options.playtimeSaveInterval {
                lastSave = Date()
                saveProgress(gameBaseline: gameBaseline, totalBaseline: totalBaseline)
            }
        }

        // 10. Cleanup (mirrors on_process_exit)
        if !isFileRun {
            ProcessScanner.killByFaugusID(gameID)
            let post = options.postLaunch ?? game.postLaunch
            if !post.isEmpty {
                var env = plan.environment
                env.removeValue(forKey: "FAUGUSID")
                spawnHook(post, env: env)
            }
            saveProgress(gameBaseline: gameBaseline, totalBaseline: totalBaseline)
            try? running.unmark(gameID: gameID)
            running.clearStopRequest(gameID: gameID)
        }
        let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        emit(.exited(status: gameExit ?? -1, playtimeSeconds: seconds))
        return nil
    }

    private static let interestingKeys: Set = ["FAUGUSID", "PATH"]

    // MARK: Pieces

    private func resolveRunner(game: Game, config: FaugusConfig) async -> (InstalledRunner?, SupervisorFailure?) {
        let store = RunnerStore(paths: paths)
        let defaultRunner = config.defaultRunner
        let wanted = game.runner.isEmpty ? "Default" : game.runner
        let identifier = wanted == "Default" ? defaultRunner : wanted
        var resolution = store.resolve(wanted, defaultRunner: defaultRunner)

        let isLatest = WineFlavor.allCases.contains { $0.latestIdentifier == identifier }
        // FAUGUS_DISABLE_UPDATES (set when running a file in a game's prefix) skips the update
        // check only; a runner that is missing altogether is still installed.
        let allowed = options.allowDownloads
        let updatesAllowed = allowed && ProcessInfo.processInfo.environment["FAUGUS_DISABLE_UPDATES"] == nil
        let wantsUpdateCheck = isLatest && options.checkForRunnerUpdates && config.bool("automatic-updates")

        var needInstall: RemoteRunner?
        switch resolution {
        case let .installed(r):
            if wantsUpdateCheck, updatesAllowed, let flavor = r.flavor,
               let remotes = try? await options.feed(),
               let latest = GcenxFeed.latest(flavor, in: remotes),
               VersionKey(latest.version) > VersionKey(r.version ?? "")
            {
                needInstall = latest
            }
        case let .missingLatest(flavor):
            guard allowed else { return (nil, .runnerNotFound(identifier)) }
            do {
                let remotes = try await options.feed()
                guard let latest = GcenxFeed.latest(flavor, in: remotes)
                else { return (nil, .runnerNotFound(identifier)) }
                needInstall = latest
            } catch { return (nil, .runnerInstallFailed("\(error)")) }
        case let .missing(name):
            guard allowed, let remotes = try? await options.feed(),
                  let match = remotes.first(where: { $0.directoryName == name })
            else { return (nil, .runnerNotFound(name)) }
            needInstall = match
        }

        if let remote = needInstall {
            do {
                _ = try await RunnerInstaller(paths: paths).install(remote) { [sink] p in
                    sink(.downloadingRunner(name: remote.directoryName, progress: p))
                }
                resolution = store.resolve(wanted, defaultRunner: defaultRunner)
            } catch {
                // A failed *update* keeps the installed runner; a failed first install is fatal.
                if case .installed = resolution {
                    log.write("runner update failed: \(error)")
                } else {
                    return (nil, .runnerInstallFailed("\(error)"))
                }
            }
        }
        if case let .installed(r) = resolution {
            return (r, nil)
        }
        return (nil, .runnerNotFound(identifier))
    }

    /// A Steam-type game: Steam starts and owns it, so there is no Wine, no prefix, no running
    /// state, no stop and no playtime (Steam keeps its own; upstream behaves the same).
    private func runSteamGame(_ game: Game) async -> SupervisorFailure? {
        emit(.preparing(title: game.title))
        guard let url = SteamLaunch.url(appID: game.path, gameArguments: game.gameArguments) else {
            return .launchFailed("\"\(game.path)\" is not a Steam app id")
        }
        guard SteamLibrary(home: paths.home).isSteamInstalled(home: paths.home) else {
            return .launchFailed("Steam is not installed")
        }
        try? PlaytimeStore(paths: paths).touchLastPlayed(gameID: game.gameID)
        guard options.openSteamURL(url) else { return .launchFailed("Could not start Steam") }
        emit(.running(pid: 0))
        try? await Task.sleep(for: options.steamSplashDuration)
        return nil
    }

    private func gameProcessExited(_ status: Int32) {
        gameExit = status
        log.write("wine process exited with status \(status)")
    }

    private func waitForWineserver(runner: InstalledRunner, env: [String: String]) {
        do {
            let pid = try ProcessSpawner.spawn(
                argv: [runner.wineserverBinary, "-w"],
                options: .init(workingDirectory: nil, environment: env, newSession: false)
            )
            Task { [weak self] in
                _ = await ProcessSpawner.waitForExit(pid: pid)
                await self?.serverWaitFinished()
            }
        } catch {
            serverWaitDone = true
        }
    }

    private func serverWaitFinished() {
        serverWaitDone = true
    }

    /// Graceful, then forced (plan section 5 "Stop"). The grace period ends as soon as the
    /// game process has exited and nothing tagged with this game's `FAUGUSID` is left.
    private func terminate(runner: InstalledRunner, prefix: String, env: [String: String]) async {
        let t0 = Date()
        func stamp(_ what: String) {
            log.write(String(format: "stop +%.2fs: %@", Date().timeIntervalSince(t0), what))
        }
        if gamePID > 0 {
            killpg(gamePID, SIGTERM)
        }
        stamp("SIGTERM sent")
        var serverKill: pid_t?
        if !prefixSharedWithOtherRunningGame(prefix: prefix) {
            // Not awaited: Wine's own graceful shutdown can take 10 s, far beyond our grace.
            serverKill = try? ProcessSpawner.spawn(
                argv: [runner.wineserverBinary, "-k"],
                options: .init(workingDirectory: nil, environment: env, newSession: false)
            )
            stamp("wineserver -k started")
        }
        let graceEnd = Date().addingTimeInterval(Double(options.stopGrace.components.seconds)
            + Double(options.stopGrace.components.attoseconds) / 1e18)
        while Date() < graceEnd {
            if gameExit != nil, ProcessScanner.pids(withEnvironment: "FAUGUSID", equalTo: gameID).isEmpty {
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        let leftovers = ProcessScanner.killByFaugusID(gameID)
        if let serverKill, ProcessSpawner.isAlive(serverKill) {
            kill(serverKill, SIGKILL)
        }
        if gameExit == nil, gamePID > 0 {
            killpg(gamePID, SIGKILL)
        }
        stamp("done (force-killed \(leftovers.count))")
        // Everything for this game is gone; there is no point waiting for the idle wineserver.
        if gameExit != nil || leftovers.isEmpty {
            serverWaitDone = true
        }
    }

    private func prefixSharedWithOtherRunningGame(prefix: String) -> Bool {
        let others = running.load().keys.filter { $0 != gameID }
        guard !others.isEmpty else { return false }
        let games = (try? GamesStore(paths: paths).loadAll()) ?? []
        return games.contains { others.contains($0.gameID) && paths.expand($0.prefix) == prefix }
    }

    private func saveProgress(gameBaseline: Int, totalBaseline: Int) {
        let runtime = Int(Date().timeIntervalSince(startedAt))
        try? PlaytimeStore(paths: paths).save(
            gameID: gameID, gameBaseline: gameBaseline, totalBaseline: totalBaseline, runtimeSeconds: runtime
        )
    }

    private func spawnHook(_ command: String, env: [String: String]) {
        _ = try? ProcessSpawner.spawn(
            argv: ["/bin/sh", "-c", command],
            options: .init(workingDirectory: nil, environment: env, newSession: true)
        )
    }
}
