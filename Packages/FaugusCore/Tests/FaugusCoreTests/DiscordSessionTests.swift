import Darwin
@testable import FaugusCore
import Foundation
import Testing

extension DiscordTests {
    // MARK: Processes

    @Test func processArgumentBlockIsParsed() throws {
        var block: [UInt8] = [2, 0, 0, 0]
        block += Array("/usr/bin/wine\0\0\0".utf8)
        block += Array("C:\\windows\\game.exe\0--flag\0".utf8)
        block += Array("A=1\0\0B=two=2\0".utf8)
        let parsed = try #require(ProcessInspector.parseProcessArguments(block))
        #expect(parsed.executablePath == "/usr/bin/wine")
        #expect(parsed.arguments == ["C:\\windows\\game.exe", "--flag"])
        #expect(parsed.environment == ["A": "1", "B": "two=2"])
        #expect(ProcessInspector.parseProcessArguments([1, 0]) == nil)
    }

    @Test func theOwnProcessCanBeInspected() throws {
        let details = try #require(ProcessInspector.arguments(of: getpid()))
        #expect(!details.executablePath.isEmpty)
        #expect(!details.arguments.isEmpty)
        #expect(!details.environment.isEmpty)
        #expect(ProcessInspector.name(of: getpid())?.isEmpty == false)
        #expect(ProcessInspector.workingDirectory(of: getpid())?.hasPrefix("/") == true)
    }

    @Test func taggedProcessesBecomeCandidates() async throws {
        let tag = "discord-test-" + UUID().uuidString
        // macOS hides the environment of Apple platform binaries (`/bin/sleep`).
        let directory = NSTemporaryDirectory() + "faugus-discord-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let sourceFile = directory + "/sleeper.c"
        try "#include <unistd.h>\nint main(void){ sleep(30); return 0; }\n".write(
            toFile: sourceFile, atomically: true, encoding: .utf8
        )
        let sleepCopy = directory + "/sleeper"
        let compileResult = try await ProcessRunner.run("/usr/bin/clang", ["-o", sleepCopy, sourceFile])
        #expect(compileResult.succeeded, "clang: \(compileResult.stderr)")

        var environment = ProcessInfo.processInfo.environment
        environment["FAUGUSID"] = tag
        let pid = try ProcessSpawner.spawn(
            commandLine: [sleepCopy],
            options: .init(workingDirectory: "/tmp", environment: environment)
        )
        defer { kill(pid, SIGKILL) }
        try await Task.sleep(for: .milliseconds(200))
        let candidates = ProcessInspector.candidates(withEnvironment: "FAUGUSID", equalTo: tag)
        let candidate = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(candidate.name == "sleeper")
        #expect(candidate.firstArgument == sleepCopy)
        #expect(candidate.workingDirectory.map { $0.hasSuffix("tmp") } == true)
        #expect(ProcessInspector.candidates(withEnvironment: "FAUGUSID", equalTo: tag + "-other").isEmpty)
        kill(pid, SIGKILL)
        _ = await ProcessSpawner.waitForExit(pid: pid)
    }

    // MARK: Session

    private func makeConfiguration(server: FakeDiscordServer) -> DiscordPresenceConfiguration {
        var configuration = DiscordPresenceConfiguration()
        configuration.socketDirectories = [server.directory]
        configuration.pollInterval = .milliseconds(40)
        configuration.processID = 4242
        configuration.sessionStartDate = Date(timeIntervalSince1970: 1_700_000_000.9)
        return configuration
    }

    private func makeSession(
        server: FakeDiscordServer, index: DiscordDetectableIndex = DiscordDetectableIndex(),
        processes: LockedValue<[ProcessCandidate]> = LockedValue([]),
        others: LockedValue<[String]> = LockedValue([])
    ) -> DiscordPresenceSession {
        let targetResolver = DiscordTargetResolver(
            game: DiscordGameIdentity(gameID: "this-game", title: "Fake Title", executablePath: "/Games/fake.exe"),
            processProvider: { processes.value }, otherRunningGameIDs: { others.value },
            iconProvider: { "https://example.com/i.png" }
        )
        return DiscordPresenceSession(
            loadIndex: { index }, resolver: targetResolver, configuration: makeConfiguration(server: server)
        )
    }

    @Test func theSessionAnnouncesTheGenericActivityWithTheSessionStartTime() async throws {
        let server = FakeDiscordServer()
        try server.start()
        defer { server.stop() }
        let session = makeSession(server: server)
        await session.start()
        await session.start()
        #expect(await waitUntil { server.receivedActivities.count == 1 })

        let received = try #require(server.receivedActivities.first)
        #expect(received.clientID == DiscordApplication.clientID)
        let payload = try #require(received.payload.objectValue)
        #expect(payload["cmd"]?.stringValue == "SET_ACTIVITY")
        #expect(payload["nonce"]?.stringValue?.isEmpty == false)
        let arguments = try #require(payload["args"]?.objectValue)
        #expect(arguments["pid"]?.intValue == 4242)
        let activity = try #require(arguments["activity"]?.objectValue)
        #expect(activity["timestamps"] == ["start": 1_700_000_000])
        #expect(activity["details"]?.stringValue == "Fake Title")
        #expect(activity["status_display_type"]?.intValue == 2)
        #expect(activity["assets"] == ["large_image": "https://example.com/i.png"])
        #expect(activity.keys.first == "timestamps")

        // Nothing changed, so there is no new connection and no repeated activity.
        try? await Task.sleep(for: .milliseconds(250))
        #expect(server.handshakeClientIDs.count == 1)
        #expect(server.receivedActivities.count == 1)

        await session.stop()
        await session.stop()
        #expect(await waitUntil { server.closedConnectionCount == 1 && server.openConnectionCount == 0 })
    }

    @Test func aChangedTargetReconnectsWithTheNewApplication() async throws {
        let server = FakeDiscordServer()
        try server.start()
        defer { server.stop() }
        let index = try targetIndex()
        let processes = LockedValue<[ProcessCandidate]>([])
        let session = makeSession(server: server, index: index, processes: processes)
        await session.start()
        #expect(await waitUntil { server.receivedActivities.count == 1 })

        processes.value = [ProcessCandidate(name: "game.exe", firstArgument: "")]
        #expect(await waitUntil { server.receivedActivities.count == 2 })
        #expect(server.handshakeClientIDs == [DiscordApplication.clientID, "600"])
        #expect(await waitUntil { server.closedConnectionCount == 1 })
        let second = try #require(server.receivedActivities.last)
        #expect(second.clientID == "600")
        let activity = try #require(second.payload.objectValue?["args"]?.objectValue?["activity"]?.objectValue)
        #expect(activity == ["timestamps": ["start": 1_700_000_000]])

        await session.stop()
        #expect(await waitUntil { server.closedConnectionCount == 2 && server.openConnectionCount == 0 })
    }

    @Test func nothingIsAnnouncedWhileAnotherGameRuns() async throws {
        let server = FakeDiscordServer()
        try server.start()
        defer { server.stop() }
        let others = LockedValue(["another-game"])
        let session = makeSession(server: server, others: others)
        await session.start()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(server.handshakeClientIDs.isEmpty)

        others.value = []
        #expect(await waitUntil { server.receivedActivities.count == 1 })
        others.value = ["another-game"]
        // The announced game stays announced until the target changes to nil: the connection closes.
        #expect(await waitUntil { server.closedConnectionCount == 1 })
        await session.stop()
        #expect(await waitUntil { server.openConnectionCount == 0 })
    }

    @Test func theSessionRetriesUntilDiscordIsThere() async throws {
        let server = FakeDiscordServer()
        defer { server.stop() }
        let session = makeSession(server: server)
        await session.start()
        try? await Task.sleep(for: .milliseconds(250))
        #expect(server.handshakeClientIDs.isEmpty)
        try server.start()
        #expect(await waitUntil { server.receivedActivities.count == 1 })
        await session.stop()
        #expect(await waitUntil { server.openConnectionCount == 0 })
    }

    @Test func theSessionReconnectsAfterDiscordRestarts() async throws {
        let server = FakeDiscordServer()
        try server.start()
        defer { server.stop() }
        let session = makeSession(server: server)
        await session.start()
        #expect(await waitUntil { server.receivedActivities.count == 1 })
        server.dropConnections()
        // Failed reconnect attempts (Discord still starting) are closed on the server side as well.
        #expect(await waitUntil { server.closedConnectionCount >= 1 })
        // Discord is back: accept again.
        server.restoreConnections()
        #expect(await waitUntil { server.receivedActivities.count == 2 })
        #expect(server.handshakeClientIDs.count == 2)
        await session.stop()
        #expect(await waitUntil { server.openConnectionCount == 0 })
    }

    @Test func aSessionStoppedBeforeItsFirstPollNeverConnects() async throws {
        let server = FakeDiscordServer()
        try server.start()
        defer { server.stop() }
        let session = makeSession(server: server)
        await session.start()
        await session.stop()
        await session.start() // a stopped session stays stopped
        try? await Task.sleep(for: .milliseconds(250))
        #expect(server.openConnectionCount == 0)
        #expect(server.receivedActivities.isEmpty)
    }

    // MARK: Supervisor wiring

    private func makeSupervisorHome(discordRPC: Bool) throws -> FaugusPaths {
        let paths = try TestSupport.makeTemporaryHome()
        let binDirectory = paths.runnersDirectory + "/Wine-Staging-0.0/bin"
        try FileManager.default.createDirectory(atPath: binDirectory, withIntermediateDirectories: true)
        let scripts = [
            "wine": """
            #!/bin/sh
            if [ "$1" = "--version" ]; then echo "wine-0.0 (Fake)"; exit 0; fi
            if [ "$1" = "wineboot" ]; then
                mkdir -p "$WINEPREFIX/drive_c/windows/system32" "$WINEPREFIX/drive_c/windows/syswow64"
                echo "WINE REGISTRY" > "$WINEPREFIX/system.reg"
                exit 0
            fi
            sleep 1
            exit 0
            """,
            "wineserver": "#!/bin/sh\nexit 0\n",
        ]
        for (name, body) in scripts {
            let scriptPath = binDirectory + "/" + name
            try Data(body.utf8).write(to: URL(fileURLWithPath: scriptPath))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        }
        var configuration = try FaugusConfig.load(paths: paths, language: "en_US")
        configuration.setValue("default-runner", "Wine-Staging-0.0")
        configuration.setValue("automatic-updates", bool: false)
        try configuration.save()

        var game = Game(gameID: "fake-game", title: "Fake Game")
        game.path = paths.home + "/Games/fake.exe"
        game.prefix = paths.home + "/Faugus/fake-game"
        game.discordRPC = discordRPC
        try FileManager.default.createDirectory(atPath: paths.home + "/Games", withIntermediateDirectories: true)
        try GamesStore(paths: paths).save(games: [game])
        return paths
    }

    private func makeSupervisorOptions(
        presence: FakeDiscordPresence,
        requests: LockedValue<[String]>
    ) -> SupervisorOptions {
        var options = SupervisorOptions()
        options.allowDownloads = false
        options.pollInterval = .milliseconds(100)
        options.stopGrace = .milliseconds(400)
        options.baseEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
        options.discordIconProvider = { game in "icon-of-" + game.gameID }
        options.makeDiscordPresence = { _, game, iconProvider in
            requests.update { $0.append(game.gameID) }
            presence.iconProvider.value = iconProvider
            return presence
        }
        return options
    }

    @Test func aGameWithDiscordRPCGetsASessionThatStartsAndStops() async throws {
        let paths = try makeSupervisorHome(discordRPC: true)
        defer { TestSupport.cleanup(paths) }
        let presence = FakeDiscordPresence()
        let requests = LockedValue<[String]>([])
        let supervisor = GameSupervisor(
            paths: paths, gameID: "fake-game", options: makeSupervisorOptions(presence: presence, requests: requests)
        )
        #expect(await supervisor.run() == nil)
        #expect(requests.value == ["fake-game"])
        let iconProvider = try #require(presence.iconProvider.value)
        #expect(await iconProvider() == "icon-of-fake-game")
        #expect(presence.startCount.value == 1)
        #expect(presence.stopCount.value >= 1)
    }

    @Test func gamesWithoutDiscordRPCAndFileRunsNeverTouchDiscord() async throws {
        let withoutPaths = try makeSupervisorHome(discordRPC: false)
        defer { TestSupport.cleanup(withoutPaths) }
        let presence = FakeDiscordPresence()
        let requests = LockedValue<[String]>([])
        let plain = GameSupervisor(
            paths: withoutPaths, gameID: "fake-game",
            options: makeSupervisorOptions(presence: presence, requests: requests)
        )
        #expect(await plain.run() == nil)

        let fileRunPaths = try makeSupervisorHome(discordRPC: true)
        defer { TestSupport.cleanup(fileRunPaths) }
        var fileRunOptions = makeSupervisorOptions(presence: presence, requests: requests)
        fileRunOptions.runFile = fileRunPaths.home + "/Games/setup.exe"
        let fileRun = GameSupervisor(paths: fileRunPaths, gameID: "fake-game", options: fileRunOptions)
        #expect(await fileRun.run() == nil)

        #expect(requests.value.isEmpty)
        #expect(presence.startCount.value == 0)
        #expect(presence.stopCount.value == 0)
    }
}
