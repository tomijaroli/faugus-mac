import Foundation
import Testing

@testable import FaugusCore

/// Opt-in end-to-end tests against a real Gcenx Wine runner under Rosetta 2.
///
///     FAUGUS_REAL_WINE_RUNNER=/tmp/gcenx/runner \
///     FAUGUS_DXVK_ARCHIVE=/tmp/gcenx/dxvk.tar.gz \
///     swift test --disable-sandbox --filter RealWine
///
/// `FAUGUS_REAL_WINE_RUNNER` is a directory that contains the extracted `Wine Staging.app`.
/// The Windows test programs must be built first (`TestPrograms/build.sh`).
private let runnerSource = ProcessInfo.processInfo.environment["FAUGUS_REAL_WINE_RUNNER"]
private let dxvkArchive = ProcessInfo.processInfo.environment["FAUGUS_DXVK_ARCHIVE"]

@Suite("Real Wine integration", .serialized, .enabled(if: runnerSource != nil), .timeLimit(.minutes(15)))
struct RealWineIntegrationTests {
    let programs = TestSupport.repoRoot.appendingPathComponent("TestPrograms/build").path

    /// path -> "size:mtime" for every file under `root` (symlinks not followed).
    private func snapshot(_ root: String) -> [String: String] {
        var out: [String: String] = [:]
        guard let e = FileManager.default.enumerator(atPath: root) else { return out }
        for case let rel as String in e {
            let attrs = try? FileManager.default.attributesOfItem(atPath: root + "/" + rel)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            out[rel] = "\(size):\(mtime)"
        }
        return out
    }

    private func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    private struct Rig {
        let paths: FaugusPaths
        let runnerName: String
    }

    private func makeRig(programs: String) throws -> Rig {
        let paths = try TestSupport.makeTempHome()
        let name = "Wine-Staging-11.21"
        try FileManager.default.createDirectory(atPath: paths.runnersDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: paths.runnersDir + "/" + name, withDestinationPath: runnerSource!)
        var cfg = try FaugusConfig.load(paths: paths, language: "en_US")
        cfg.setValue("default-runner", name)
        cfg.setValue("automatic-updates", bool: false)
        cfg.setValue("splash-window-enabled", bool: false)
        try cfg.save()
        return Rig(paths: paths, runnerName: name)
    }

    private func game(_ id: String, exe: String, args: String = "", graphics: GraphicsBackend? = nil, prefix: String) -> Game {
        var g = Game(gameID: id, title: id)
        g.path = programs + "/" + exe
        g.prefix = prefix
        g.gameArguments = args
        g.graphics = graphics
        return g
    }

    private func supervise(_ paths: FaugusPaths, _ id: String) async -> SupervisorFailure? {
        var o = SupervisorOptions()
        o.logs = true
        o.allowDownloads = false
        o.checkForRunnerUpdates = false
        let sup = GameSupervisor(paths: paths, gameID: id, options: o)
        return await sup.run()
    }

    private func wineLog(_ paths: FaugusPaths, _ id: String) -> String {
        read(paths.gameLogsDir(gameID: id) + "/wine.log")
    }

    @Test func runnerIsDetectedAndNeverModified() async throws {
        let before = snapshot(runnerSource!)
        let rig = try makeRig(programs: programs)
        defer { TestSupport.cleanup(rig.paths) }

        let installed = RunnerStore(paths: rig.paths).installed()
        #expect(installed.map(\.name) == [rig.runnerName])
        let caps = installed.first?.capabilities
        print("runner capabilities: \(String(describing: caps))")

        if let dxvkArchive {
            try DXVKComponent(paths: rig.paths).installArchive(at: dxvkArchive, expectedSHA256: DXVKComponent.sha256)
            #expect(DXVKComponent(paths: rig.paths).isInstalled)
        }

        let prefix = rig.paths.home + "/Faugus/shared"
        let games = [
            game("hello64", exe: "hello.exe", args: "alpha beta", graphics: .wined3d, prefix: prefix),
            game("hello32", exe: "hello32.exe", graphics: .wined3d, prefix: prefix),
            game("d3d9-wined3d", exe: "d3d9tri.exe", graphics: .wined3d, prefix: prefix),
            game("d3d11-wined3d", exe: "d3d11tri.exe", graphics: .wined3d, prefix: prefix),
            game("d3d11-dxvk", exe: "d3d11tri.exe", graphics: .dxvk, prefix: prefix),
        ]
        try GamesStore(paths: rig.paths).save(games: games)

        // 1. First run creates the prefix and runs a 64-bit console program.
        let started = Date()
        let f1 = await supervise(rig.paths, "hello64")
        print("hello64 (incl. prefix creation) took \(Date().timeIntervalSince(started))s, failure=\(String(describing: f1))")
        #expect(f1 == nil)
        #expect(PrefixManager(paths: rig.paths).isCreated(prefix: prefix))
        let log64 = wineLog(rig.paths, "hello64")
        #expect(log64.contains("hello from faugus (64-bit)"), "wine.log tail: \(log64.suffix(2000))")
        #expect(log64.contains("arg1=alpha"))
        #expect(log64.contains("arg2=beta"))
        #expect(log64.contains("FAUGUSID=hello64"))

        // 2. 32-bit program in the same (WoW64) prefix.
        #expect(await supervise(rig.paths, "hello32") == nil)
        let log32 = wineLog(rig.paths, "hello32")
        #expect(log32.contains("hello from faugus (32-bit)"), "wine.log tail: \(log32.suffix(2000))")

        // 3. Direct3D 9 and 11 on WineD3D.
        #expect(await supervise(rig.paths, "d3d9-wined3d") == nil)
        print("d3d9 log: \(wineLog(rig.paths, "d3d9-wined3d").split(separator: "\n").filter { !$0.contains(":trace:") && !$0.contains("fixme") }.suffix(8).joined(separator: "\n"))")

        #expect(await supervise(rig.paths, "d3d11-wined3d") == nil)
        let w3d = wineLog(rig.paths, "d3d11-wined3d")
        print("d3d11 wined3d: \(w3d.split(separator: "\n").filter { $0.contains("d3d11.dll=") || $0.contains("device") }.prefix(6).joined(separator: "\n"))")
        #expect(w3d.contains("d3d11.dll=builtin"), "wine.log tail: \(w3d.suffix(2000))")

        // 4. DXVK needs Vulkan; without it the plan falls back to WineD3D (GraphicsPlan).
        if dxvkArchive != nil {
            #expect(await supervise(rig.paths, "d3d11-dxvk") == nil)
            let dx = wineLog(rig.paths, "d3d11-dxvk")
            let expectDXVK = caps?.vulkan == true
            print("d3d11 dxvk (vulkan=\(expectDXVK)): \(dx.split(separator: "\n").filter { $0.contains("d3d11.dll=") }.joined(separator: "\n"))")
            #expect(dx.contains(expectDXVK ? "d3d11.dll=DXVK" : "d3d11.dll=builtin"), "wine.log tail: \(dx.suffix(2000))")
        }

        // The runner tree is byte-for-byte what we downloaded.
        let after = snapshot(runnerSource!)
        #expect(before == after, "runner tree changed")
        // No wineserver left behind for this prefix.
        #expect(ProcessScanner.pids(withEnvironment: "WINEPREFIX", equalTo: prefix).isEmpty)
    }

    @Test func stopTerminatesAProcessTreeWithinFiveSeconds() async throws {
        let rig = try makeRig(programs: programs)
        defer { TestSupport.cleanup(rig.paths) }
        let prefix = rig.paths.home + "/Faugus/stop"
        try GamesStore(paths: rig.paths).save(games: [game("spawner", exe: "spawner.exe", graphics: .wined3d, prefix: prefix)])

        var o = SupervisorOptions()
        o.logs = true
        o.allowDownloads = false
        o.checkForRunnerUpdates = false
        let sup = GameSupervisor(paths: rig.paths, gameID: "spawner", options: o)
        let task = Task { await sup.run() }

        // Wait for the child's heartbeat: the game is up and has spawned a child.
        let heartbeat = programs + "/spawner-heartbeat.txt"
        try? FileManager.default.removeItem(atPath: heartbeat)
        let deadline = Date().addingTimeInterval(180)
        let running = RunningGames(paths: rig.paths)
        while Date() < deadline, !(running.isRunning("spawner") && FileManager.default.fileExists(atPath: heartbeat)) {
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(running.isRunning("spawner"))

        let t0 = Date()
        try running.requestStop(gameID: "spawner")
        let failure = await task.value
        let elapsed = Date().timeIntervalSince(t0)
        print("stop took \(elapsed)s")
        print(read(rig.paths.gameLogsDir(gameID: "spawner") + "/faugus.log").split(separator: "\n").filter { $0.contains("stop +") }.joined(separator: "\n"))
        #expect(failure == nil)
        #expect(elapsed < 5.0)
        #expect(!running.isRunning("spawner"))
        #expect(ProcessScanner.pids(withEnvironment: "FAUGUSID", equalTo: "spawner").isEmpty)
        try? FileManager.default.removeItem(atPath: heartbeat)
    }
}
