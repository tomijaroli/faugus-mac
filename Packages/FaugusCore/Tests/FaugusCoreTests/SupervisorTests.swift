@testable import FaugusCore
import Foundation
import Testing

/// Collects supervisor events from any thread.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SupervisorEvent] = []
    func add(_ event: SupervisorEvent) {
        lock.lock()
        items.append(event)
        lock.unlock()
    }

    var all: [SupervisorEvent] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

@Suite("Game supervisor (fake Wine)", .serialized)
struct SupervisorTests {
    /// Creates `runners/Wine-Staging-0.0/bin/{wine,wineserver}` as shell scripts.
    private func installFakeRunner(_ paths: FaugusPaths, wineBody: String) throws {
        let bin = paths.runnersDirectory + "/Wine-Staging-0.0/bin"
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
            let scriptPath = bin + "/" + name
            try Data(body.utf8).write(to: URL(fileURLWithPath: scriptPath))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        }
    }

    private func setup(wineBody: String, game: (inout Game) -> Void = { _ in }) throws -> FaugusPaths {
        let paths = try TestSupport.makeTemporaryHome()
        try installFakeRunner(paths, wineBody: wineBody)
        var configuration = try FaugusConfig.load(paths: paths, language: "en_US")
        configuration.setValue("default-runner", "Wine-Staging-0.0")
        configuration.setValue("automatic-updates", bool: false)
        try configuration.save()

        var fakeGame = Game(gameID: "fake-game", title: "Fake Game")
        fakeGame.path = paths.home + "/Games/fake.exe"
        fakeGame.prefix = paths.home + "/Faugus/fake-game"
        game(&fakeGame)
        try FileManager.default.createDirectory(atPath: paths.home + "/Games", withIntermediateDirectories: true)
        try GamesStore(paths: paths).save(games: [fakeGame])
        return paths
    }

    private func options() -> SupervisorOptions {
        var supervisorOptions = SupervisorOptions()
        supervisorOptions.allowDownloads = false
        supervisorOptions.pollInterval = .milliseconds(100)
        supervisorOptions.playtimeSaveInterval = 0.5
        supervisorOptions.stopGrace = .milliseconds(400)
        supervisorOptions.baseEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
        return supervisorOptions
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
        let supervisor = GameSupervisor(paths: paths, gameID: "fake-game", options: options()) { events.add($0) }

        let failure = await supervisor.run()
        #expect(failure == nil)

        let kinds = events.all.map { event -> String in
            switch event {
            case .preparing: "preparing"
            case .checkingRosetta: "rosetta"
            case .creatingPrefix: "prefix"
            case .starting: "starting"
            case .running: "running"
            case .exited: "exited"
            default: "other"
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
        let configuration = try FaugusConfig.load(paths: paths)
        #expect(configuration.int("playtime") >= 2)

        #expect(RunningGames(paths: paths).load().isEmpty)
        #expect(FileManager.default.fileExists(atPath: paths.gameLogsDirectory(gameID: "fake-game") + "/faugus.log"))
        // Logs off: no wine.log.
        #expect(!FileManager.default.fileExists(atPath: paths.gameLogsDirectory(gameID: "fake-game") + "/wine.log"))
    }

    @Test func runFileUsesThePrefixButIsNotTheGame() async throws {
        let paths = try setup(wineBody: """
        echo "args: $@" > "$WINEPREFIX/ran-file.txt"
        echo "id: [$FAUGUSID]" >> "$WINEPREFIX/ran-file.txt"
        echo "pwd: $(pwd)" >> "$WINEPREFIX/ran-file.txt"
        echo "running: $(ls "$FAUGUS_TEST_STATE" 2>/dev/null)" >> "$WINEPREFIX/ran-file.txt"
        exit 0
        """) { [home = NSTemporaryDirectory()] in $0.preLaunch = "touch '\(home)faugus-hook-marker-runfile'"
            $0.postLaunch = $0.preLaunch
        }
        defer { TestSupport.cleanup(paths) }
        var supervisorOptions = options()
        supervisorOptions.runFile = paths.home + "/Downloads/setup.msi"
        supervisorOptions.baseEnvironment["FAUGUS_TEST_STATE"] = paths.stateDirectory
        let supervisor = GameSupervisor(paths: paths, gameID: "fake-game", options: supervisorOptions)
        let failure = await supervisor.run()
        #expect(failure == nil)

        let prefix = paths.home + "/Faugus/fake-game"
        let ran = try String(contentsOfFile: prefix + "/ran-file.txt", encoding: .utf8)
        #expect(ran.contains("msiexec /i") && ran.contains("setup.msi"))
        #expect(ran.contains("id: []"))
        #expect(ran.contains("/Games")) // the game's folder
        // No hooks, no playtime, no running state.
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: NSTemporaryDirectory() + "faugus-hook-marker-runfile"))
        let game = try GamesStore(paths: paths).loadAll().first!
        #expect(game.playtime == 0)
        #expect(game.lastPlayed.isEmpty)
        #expect(RunningGames(paths: paths).load().isEmpty)
    }

    @Test func winecfgRunsInTheRequestedPrefixAndCreatesIt() async throws {
        let paths = try setup(wineBody: """
        echo "args: $@" > "$WINEPREFIX/ran-tool.txt"
        echo "id: [$FAUGUSID]" >> "$WINEPREFIX/ran-tool.txt"
        exit 0
        """)
        defer { TestSupport.cleanup(paths) }
        var supervisorOptions = options()
        supervisorOptions.runFile = "winecfg"
        var adhoc = Game(gameID: "my-new-game", title: "my-new-game")
        let prefix = paths.home + "/Faugus/my-new-game"
        adhoc.prefix = prefix
        adhoc.runner = "Default"
        supervisorOptions.adhocGame = adhoc
        let failure = await GameSupervisor(paths: paths, gameID: "my-new-game", options: supervisorOptions).run()
        #expect(failure == nil)
        let ran = try String(contentsOfFile: prefix + "/ran-tool.txt", encoding: .utf8)
        #expect(ran.contains("args: winecfg"))
        #expect(ran.contains("id: []"))
        // The saved game list is untouched: the dialog's game does not exist yet.
        #expect(try GamesStore(paths: paths).loadAll().allSatisfy { $0.gameID != "my-new-game" })
    }

    @Test func runFileLeavesARunningGameAlone() async throws {
        let paths = try setup(wineBody: """
        case "$1" in
          regedit) exit 0 ;;
          *) sleep 5 ;;
        esac
        """)
        defer { TestSupport.cleanup(paths) }
        let game = GameSupervisor(paths: paths, gameID: "fake-game", options: options())
        let gameTask = Task { await game.run() }
        var seen = false
        for _ in 0 ..< 40 {
            try await Task.sleep(for: .milliseconds(100))
            if RunningGames(paths: paths).isRunning("fake-game") {
                seen = true
                break
            }
        }
        #expect(seen)

        var supervisorOptions = options()
        supervisorOptions.runFile = paths.home + "/tweak.reg"
        let other = GameSupervisor(paths: paths, gameID: "fake-game", options: supervisorOptions)
        _ = await other.run()
        // The file run finished; the game is still marked running and not killed.
        #expect(RunningGames(paths: paths).isRunning("fake-game"))
        try RunningGames(paths: paths).requestStop(gameID: "fake-game")
        _ = await gameTask.value
    }

    @Test func runningStateIsVisibleWhileRunning() async throws {
        let paths = try setup(wineBody: "echo out; sleep 3")
        defer { TestSupport.cleanup(paths) }
        let supervisor = GameSupervisor(paths: paths, gameID: "fake-game", options: options())
        let task = Task { await supervisor.run() }

        var seen = false
        for _ in 0 ..< 40 {
            try await Task.sleep(for: .milliseconds(100))
            if RunningGames(paths: paths).isRunning("fake-game") {
                seen = true
                break
            }
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
        let supervisor = GameSupervisor(paths: paths, gameID: "fake-game", options: options()) { events.add($0) }
        let task = Task { await supervisor.run() }

        // Wait for `running`, then stop.
        for _ in 0 ..< 60 {
            try await Task.sleep(for: .milliseconds(100))
            if events.all.contains(where: {
                if case .running = $0 {
                    true
                } else {
                    false
                }
            }) {
                break
            }
        }
        let startTime = Date()
        try RunningGames(paths: paths).requestStop(gameID: "fake-game")
        let failure = await task.value
        #expect(failure == nil)
        #expect(Date().timeIntervalSince(startTime) < 5)
        #expect(events.all.contains(.stopping))
        let exited: [Int32] = events.all.compactMap { event in
            guard case let .exited(status, _) = event else { return nil }
            return status
        }
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
        var supervisorOptions = options()
        supervisorOptions.logs = true
        let failure = await GameSupervisor(paths: paths, gameID: "fake-game", options: supervisorOptions).run()
        #expect(failure == nil)
        let wineLog = try String(
            contentsOfFile: paths.gameLogsDirectory(gameID: "fake-game") + "/wine.log",
            encoding: .utf8
        )
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
        if case .launchFailed? = failure {}
        else {
            Issue.record("expected launchFailed, got \(String(describing: failure))")
        }
    }

    @Test func playtimeSaveKeepsOtherGamesAndFieldsIntact() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        try TestSupport.install(fixture: "games.extra-fields.json", at: paths.gamesJSON)
        let before = try JSONParser.parse(Data(contentsOf: URL(fileURLWithPath: paths.gamesJSON))).arrayValue!

        try PlaytimeStore(paths: paths).save(
            gameID: "celeste",
            gameBaseline: 12345,
            totalBaseline: 14000,
            runtimeSeconds: 100
        )
        let after = try JSONParser.parse(Data(contentsOf: URL(fileURLWithPath: paths.gamesJSON))).arrayValue!
        #expect(after.count == before.count)
        let celeste = after[0].objectValue!
        #expect(celeste["playtime"] == .int(12445))
        #expect(celeste["last_played"] != before[0].objectValue!["last_played"])
        #expect(celeste["graphics"] == "wined3d") // extra field preserved
        #expect(Array(after.dropFirst()) == Array(before.dropFirst()))
        #expect(try FaugusConfig.load(paths: paths).int("playtime") == 14100)
    }

    @Test func scannerFindsTaggedProcesses() async throws {
        let id = "scan-" + UUID().uuidString
        var environment = ProcessInfo.processInfo.environment
        environment["FAUGUSID"] = id

        // macOS hides the environment of Apple platform binaries (/bin/sleep), and hosted CI
        // runners also hide copies of them. Wine's binaries are third-party ad-hoc signed, so
        // mirror that with a tiny compiled program.
        let directory = NSTemporaryDirectory() + "faugus-scan-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let sourceFile = directory + "/sleeper.c"
        try "#include <unistd.h>\nint main(void){ sleep(30); return 0; }\n".write(
            toFile: sourceFile,
            atomically: true,
            encoding: .utf8
        )
        let sleepCopy = directory + "/sleeper"
        let compileResult = try await ProcessRunner.run("/usr/bin/clang", ["-o", sleepCopy, sourceFile])
        #expect(compileResult.succeeded, "clang: \(compileResult.stderr)")

        let pid = try ProcessSpawner.spawn(commandLine: [sleepCopy, "30"], options: .init(environment: environment))
        defer { kill(pid, SIGKILL)
            var exitStatus: Int32 = 0
            waitpid(pid, &exitStatus, 0)
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(ProcessScanner.pids(withEnvironment: "FAUGUSID", equalTo: id) == [pid])
        #expect(ProcessScanner.environment(of: pid)?["FAUGUSID"] == id)
        let killed = ProcessScanner.killByFaugusID(id)
        #expect(killed == [pid])
        #expect(await ProcessSpawner.waitForExit(pid: pid) == 128 + Int32(SIGKILL))
        #expect(ProcessScanner.pids(withEnvironment: "FAUGUSID", equalTo: id).isEmpty)
    }

    /// Wine renames itself by overwriting the argv block, leaving empty strings before the
    /// environment. The scanner must read past them (regression: orphaned winedevice.exe).
    @Test func scannerReadsPastARewrittenProcessTitle() async throws {
        let id = "retitle-" + UUID().uuidString
        let directory = NSTemporaryDirectory() + "faugus-retitle-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let sourceFile = directory + "/retitle.c"
        try """
        #include <string.h>
        #include <unistd.h>
        int main(int argc, char **argv) {
            size_t n = strlen(argv[0]);
            memset(argv[0], 0, n);
            strcpy(argv[0], "C:\\\\windows\\\\x.exe");
            sleep(30);
            return 0;
        }
        """.write(toFile: sourceFile, atomically: true, encoding: .utf8)
        let executable = directory + "/retitle"
        let compileResult = try await ProcessRunner.run("/usr/bin/clang", ["-o", executable, sourceFile])
        #expect(compileResult.succeeded, "clang: \(compileResult.stderr)")
        _ = try await ProcessRunner.run("/usr/bin/codesign", ["--force", "-s", "-", executable])

        var environment = ProcessInfo.processInfo.environment
        environment["FAUGUSID"] = id
        let pid = try ProcessSpawner.spawn(commandLine: [executable], options: .init(environment: environment))
        defer { kill(pid, SIGKILL)
            var exitStatus: Int32 = 0
            waitpid(pid, &exitStatus, 0)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(ProcessScanner.pids(withEnvironment: "FAUGUSID", equalTo: id) == [pid])
    }
}
