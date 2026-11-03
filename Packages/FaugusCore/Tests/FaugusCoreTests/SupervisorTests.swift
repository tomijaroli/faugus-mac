import Foundation
import Testing

@testable import FaugusCore

/// Collects supervisor events from any thread.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SupervisorEvent] = []
    func add(_ e: SupervisorEvent) { lock.lock(); items.append(e); lock.unlock() }
    var all: [SupervisorEvent] { lock.lock(); defer { lock.unlock() }; return items }
}

@Suite("Game supervisor (fake Wine)", .serialized)
struct SupervisorTests {
    /// Creates `runners/Wine-Staging-0.0/bin/{wine,wineserver}` as shell scripts.
    private func installFakeRunner(_ paths: FaugusPaths, wineBody: String) throws {
        let bin = paths.runnersDir + "/Wine-Staging-0.0/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        let wine = """
            #!/bin/sh
            if [ "$1" = "--version" ]; then echo "wine-0.0 (Fake)"; exit 0; fi
            if [ "$1" = "wineboot" ]; then
                mkdir -p "$WINEPREFIX/drive_c/windows/system32" "$WINEPREFIX/drive_c/windows/syswow64"
                echo "WINE REGISTRY" > "$WINEPREFIX/system.reg"
                exit 0
            fi
            \(wineBody)
            """
        let server = """
            #!/bin/sh
            case "$1" in
              -k) echo killed >> "$WINEPREFIX/server.log"; pkill -TERM -f "FAKEGAME-$FAUGUSID" ; exit 0 ;;
              -w) exit 0 ;;
            esac
            """
        for (name, body) in [("wine", wine), ("wineserver", server)] {
            let p = bin + "/" + name
            try Data(body.utf8).write(to: URL(fileURLWithPath: p))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p)
        }
    }

    private func setup(wineBody: String, game: (inout Game) -> Void = { _ in }) throws -> FaugusPaths {
        let paths = try TestSupport.makeTempHome()
        try installFakeRunner(paths, wineBody: wineBody)
        var cfg = try FaugusConfig.load(paths: paths, language: "en_US")
        cfg.setValue("default-runner", "Wine-Staging-0.0")
        cfg.setValue("automatic-updates", bool: false)
        try cfg.save()

        var g = Game(gameID: "fake-game", title: "Fake Game")
        g.path = paths.home + "/Games/fake.exe"
        g.prefix = paths.home + "/Faugus/fake-game"
        game(&g)
        try FileManager.default.createDirectory(atPath: paths.home + "/Games", withIntermediateDirectories: true)
        try GamesStore(paths: paths).save(games: [g])
        return paths
    }

    private func options() -> SupervisorOptions {
        var o = SupervisorOptions()
        o.allowDownloads = false
        o.pollInterval = .milliseconds(100)
        o.playtimeSaveInterval = 5
        o.stopGrace = .milliseconds(400)
        o.baseEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
        return o
    }

    @Test func fullLifecycleCreatesPrefixRunsAndSavesPlaytime() async throws {
        let paths = try setup(wineBody: """
            echo "args: $@" > "$WINEPREFIX/ran.txt"
            echo "id: $FAUGUSID" >> "$WINEPREFIX/ran.txt"
            echo "overrides: $WINEDLLOVERRIDES" >> "$WINEPREFIX/ran.txt"
            echo "pwd: $(pwd)" >> "$WINEPREFIX/ran.txt"
            sleep 2
            exit 0
            """)
        defer { TestSupport.cleanup(paths) }
        let events = EventLog()
        let sup = GameSupervisor(paths: paths, gameID: "fake-game", options: options()) { events.add($0) }

        let failure = await sup.run()
        #expect(failure == nil)

        let kinds = events.all.map { e -> String in
            switch e {
            case .preparing: return "preparing"
            case .checkingRosetta: return "rosetta"
            case .creatingPrefix: return "prefix"
            case .starting: return "starting"
            case .running: return "running"
            case .exited: return "exited"
            default: return "other"
            }
        }
        #expect(kinds == ["preparing", "rosetta", "prefix", "starting", "running", "exited"])

        let prefix = paths.home + "/Faugus/fake-game"
        let ran = try String(contentsOfFile: prefix + "/ran.txt", encoding: .utf8)
        #expect(ran.contains("args: /") && ran.contains("fake.exe"))
        #expect(ran.contains("id: fake-game"))
        #expect(ran.contains("overrides: winemenubuilder.exe=d;d3d11,d3d10core=b"))
        #expect(ran.contains("pwd: ") && ran.contains("/Games"))

        let marker = PrefixManager(paths: paths).marker(prefix: prefix)
        #expect(marker?.runner == "Wine-Staging-0.0")
        #expect(marker?.wine == "wine-0.0 (Fake)")

        let game = try GamesStore(paths: paths).loadAll().first!
        #expect(game.playtime >= 2)
        #expect(game.lastPlayed.contains("T"))
        let cfg = try FaugusConfig.load(paths: paths)
        #expect(cfg.int("playtime") >= 2)

        #expect(RunningGames(paths: paths).load().isEmpty)
        #expect(FileManager.default.fileExists(atPath: paths.gameLogsDir(gameID: "fake-game") + "/faugus.log"))
        // Logs off: no wine.log.
        #expect(!FileManager.default.fileExists(atPath: paths.gameLogsDir(gameID: "fake-game") + "/wine.log"))
    }

    @Test func runningStateIsVisibleWhileRunning() async throws {
        let paths = try setup(wineBody: "echo out; sleep 3")
        defer { TestSupport.cleanup(paths) }
        let sup = GameSupervisor(paths: paths, gameID: "fake-game", options: options())
        let task = Task { await sup.run() }

        var seen = false
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            if RunningGames(paths: paths).isRunning("fake-game") { seen = true; break }
        }
        #expect(seen)
        try RunningGames(paths: paths).requestStop(gameID: "fake-game")
        _ = await task.value
        #expect(!RunningGames(paths: paths).isRunning("fake-game"))
    }

    @Test func stopRequestEndsTheGameQuickly() async throws {
        let paths = try setup(wineBody: "exec sleep 60")
        defer { TestSupport.cleanup(paths) }
        let events = EventLog()
        let sup = GameSupervisor(paths: paths, gameID: "fake-game", options: options()) { events.add($0) }
        let task = Task { await sup.run() }

        // Wait for `running`, then stop.
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(100))
            if events.all.contains(where: { if case .running = $0 { return true } else { return false } }) { break }
        }
        let t0 = Date()
        try RunningGames(paths: paths).requestStop(gameID: "fake-game")
        let failure = await task.value
        #expect(failure == nil)
        #expect(Date().timeIntervalSince(t0) < 5)
        #expect(events.all.contains(.stopping))
        let exited = events.all.compactMap { e -> Int32? in if case .exited(let s, _) = e { return s } else { return nil } }
        #expect(exited.count == 1)
        #expect(!FileManager.default.fileExists(atPath: paths.stopFile(gameID: "fake-game")))
        #expect(RunningGames(paths: paths).load().isEmpty)
        // wineserver -k was invoked (the prefix is not shared).
        let serverLog = try String(contentsOfFile: paths.home + "/Faugus/fake-game/server.log", encoding: .utf8)
        #expect(serverLog.contains("killed"))
    }

    @Test func logsModeWritesWineLogAndDebugEnvironment() async throws {
        let paths = try setup(wineBody: "echo \"WINEDEBUG=$WINEDEBUG\"; echo to-stderr 1>&2; exit 0")
        defer { TestSupport.cleanup(paths) }
        var o = options()
        o.logs = true
        let failure = await GameSupervisor(paths: paths, gameID: "fake-game", options: o).run()
        #expect(failure == nil)
        let wineLog = try String(contentsOfFile: paths.gameLogsDir(gameID: "fake-game") + "/wine.log", encoding: .utf8)
        #expect(wineLog.contains("WINEDEBUG=" + LaunchPlanner.logsWineDebug))
        #expect(wineLog.contains("to-stderr"))
    }

    @Test func missingGameAndMissingRunnerAreReportedNotCrashed() async throws {
        let paths = try setup(wineBody: "exit 0")
        defer { TestSupport.cleanup(paths) }
        #expect(await GameSupervisor(paths: paths, gameID: "nope", options: options()).run() == .gameNotFound("nope"))

        try RunnerInstaller(paths: paths).uninstall(name: "Wine-Staging-0.0")
        let failure = await GameSupervisor(paths: paths, gameID: "fake-game", options: options()).run()
        #expect(failure == .runnerNotFound("Wine-Staging-0.0"))
        #expect(RunningGames(paths: paths).load().isEmpty)
    }

    @Test func gameWithUnparsableArgumentsFailsCleanly() async throws {
        let paths = try setup(wineBody: "exit 0") { $0.launchArguments = "FOO='oops" }
        defer { TestSupport.cleanup(paths) }
        let failure = await GameSupervisor(paths: paths, gameID: "fake-game", options: options()).run()
        if case .launchFailed? = failure {} else { Issue.record("expected launchFailed, got \(String(describing: failure))") }
    }

    @Test func playtimeSaveKeepsOtherGamesAndFieldsIntact() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        try TestSupport.install(fixture: "games.extra-fields.json", at: paths.gamesJSON)
        let before = try JSONParser.parse(try Data(contentsOf: URL(fileURLWithPath: paths.gamesJSON))).arrayValue!

        try PlaytimeStore(paths: paths).save(gameID: "celeste", gameBaseline: 12345, totalBaseline: 14000, runtimeSeconds: 100)
        let after = try JSONParser.parse(try Data(contentsOf: URL(fileURLWithPath: paths.gamesJSON))).arrayValue!
        #expect(after.count == before.count)
        let celeste = after[0].objectValue!
        #expect(celeste["playtime"] == .int(12445))
        #expect(celeste["last_played"] != before[0].objectValue!["last_played"])
        #expect(celeste["graphics"] == "wined3d")  // extra field preserved
        #expect(Array(after.dropFirst()) == Array(before.dropFirst()))
        #expect(try FaugusConfig.load(paths: paths).int("playtime") == 14100)
    }

    @Test func scannerFindsTaggedProcesses() async throws {
        let id = "scan-" + UUID().uuidString
        var env = ProcessInfo.processInfo.environment
        env["FAUGUSID"] = id

        // macOS hides the environment of Apple platform binaries (/bin/sleep). Wine's binaries are
        // ad-hoc signed, so use an ad-hoc signed copy to mirror them.
        let dir = NSTemporaryDirectory() + "faugus-scan-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sleepCopy = dir + "/sleep"
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: sleepCopy)
        let sign = try await ProcessRunner.run("/usr/bin/codesign", ["--force", "-s", "-", sleepCopy])
        #expect(sign.succeeded, "codesign: \(sign.stderr)")

        let pid = try ProcessSpawner.spawn(argv: [sleepCopy, "30"], options: .init(environment: env))
        defer { kill(pid, SIGKILL); var s: Int32 = 0; waitpid(pid, &s, 0) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(ProcessScanner.pids(withEnvironment: "FAUGUSID", equalTo: id) == [pid])
        #expect(ProcessScanner.environment(of: pid)?["FAUGUSID"] == id)
        let killed = ProcessScanner.killByFaugusID(id)
        #expect(killed == [pid])
        #expect(await ProcessSpawner.waitForExit(pid: pid) == 128 + Int32(SIGKILL))
        #expect(ProcessScanner.pids(withEnvironment: "FAUGUSID", equalTo: id).isEmpty)
    }
}
