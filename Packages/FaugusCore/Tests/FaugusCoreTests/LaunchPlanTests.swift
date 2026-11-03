@testable import FaugusCore
import Foundation
import Testing

@Suite("Launch planning")
struct LaunchPlanTests {
    private func fakeRunner(caps: RunnerCapabilities = RunnerCapabilities(vulkan: true, sdl: true, gstreamer: true))
        -> InstalledRunner
    {
        InstalledRunner(
            name: "Wine-Staging-11.21", directory: "/r/Wine-Staging-11.21",
            wineRoot: "/r/Wine-Staging-11.21/Wine Staging.app/Contents/Resources/wine",
            flavor: .staging, version: "11.21", capabilities: caps
        )
    }

    private func env(_ plan: LaunchPlan, _ key: String) -> String? {
        plan.environment[key]
    }

    private func makeConfig() throws -> (FaugusConfig, FaugusPaths) {
        let paths = FaugusPaths(home: NSTemporaryDirectory() + "faugus-plan-\(UUID().uuidString)")
        return try (FaugusConfig.load(paths: paths, language: "en_US"), paths)
    }

    @Test func basicExeLaunch() throws {
        let (cfg, paths) = try makeConfig()
        defer { try? FileManager.default.removeItem(atPath: paths.home) }
        var g = Game(gameID: "celeste", title: "Celeste")
        g.path = "/Games/Celeste/Celeste.exe"
        g.prefix = "/Users/u/Faugus/celeste"
        let gfx = GraphicsPlan.resolve(requested: .dxvk, capabilities: fakeRunner().capabilities)
        let plan = try LaunchPlanner.plan(
            game: g, config: cfg, runner: fakeRunner(), paths: paths, logs: false, graphics: gfx,
            baseEnvironment: ["PATH": "/usr/bin", "HOME": "/Users/u"]
        )

        #expect(plan.argv == [fakeRunner().wineBinary, "/Games/Celeste/Celeste.exe"])
        #expect(env(plan, "WINEPREFIX") == "/Users/u/Faugus/celeste")
        #expect(env(plan, "FAUGUSID") == "celeste")
        #expect(env(plan, "WINEDEBUG") == "-all")
        #expect(env(plan, "WINEDLLOVERRIDES") == "winemenubuilder.exe=d;d3d11,d3d10core=n,b")
        #expect(env(plan, "MVK_CONFIG_RESUME_LOST_DEVICE") == "1")
        #expect(env(plan, "DXVK_ASYNC") == nil)
        #expect(env(plan, "PATH")!.hasPrefix(fakeRunner().wineRoot + "/bin:/usr/bin"))
        #expect(plan.logDirectory == paths.logsDir + "/celeste")
    }

    @Test func launchSpecByExtension() {
        let w = "/w/wine"
        #expect(LaunchSpec.command(forPath: "/a/b.exe", wine: w) == [w, "/a/b.exe"])
        #expect(LaunchSpec.command(forPath: "/a/b.EXE", wine: w) == [w, "/a/b.EXE"])
        #expect(LaunchSpec.command(forPath: "/a/b.msi", wine: w) == [w, "msiexec", "/i", "/a/b.msi"])
        #expect(LaunchSpec.command(forPath: "/a/b.bat", wine: w) == [w, "cmd", "/c", "/a/b.bat"])
        #expect(LaunchSpec.command(forPath: "/a/b.lnk", wine: w) == [w, "start", "/unix", "/a/b.lnk"])
        #expect(LaunchSpec.command(forPath: "/a/b.reg", wine: w) == [w, "regedit", "/a/b.reg"])
    }

    @Test func userEnvironmentArgumentsAndPrecedence() throws {
        let (cfg, paths) = try makeConfig()
        defer { try? FileManager.default.removeItem(atPath: paths.home) }
        var g = Game(gameID: "w3", title: "W3")
        g.path = "/g/w3.exe"
        g.prefix = "/p"
        g.launchArguments = #"WINEDLLOVERRIDES="dxgi=n;d3d11=b" FOO=1 BAR="a b" caffeinate -i"#
        g.gameArguments = "-windowed --res='1920 1080'"
        let gfx = GraphicsPlan.resolve(requested: .dxvk, capabilities: fakeRunner().capabilities)
        let plan = try LaunchPlanner.plan(
            game: g, config: cfg, runner: fakeRunner(), paths: paths, logs: false, graphics: gfx,
            globalEnvironment: [("BAR", "global"), ("WINEDEBUG", "err+all")],
            baseEnvironment: [:]
        )

        #expect(plan.argv == ["caffeinate", "-i", fakeRunner().wineBinary, "/g/w3.exe", "-windowed", "--res=1920 1080"])
        #expect(env(plan, "FOO") == "1")
        // Global envar.json wins over the game's launch_arguments, like upstream.
        #expect(env(plan, "BAR") == "global")
        #expect(env(plan, "WINEDEBUG") == "err+all")
        // User override for d3d11 replaces Faugus's; Faugus's d3d10core stays.
        #expect(env(plan, "WINEDLLOVERRIDES") == "winemenubuilder.exe=d;d3d10core=n,b;dxgi=n;d3d11=b")
    }

    @Test func logsMode() throws {
        let (cfg, paths) = try makeConfig()
        defer { try? FileManager.default.removeItem(atPath: paths.home) }
        var g = Game(gameID: "x", title: "X")
        g.path = "/g/x.exe"
        let gfx = GraphicsPlan.resolve(requested: .wined3d, capabilities: fakeRunner().capabilities)
        let plan = try LaunchPlanner.plan(
            game: g,
            config: cfg,
            runner: fakeRunner(),
            paths: paths,
            logs: true,
            graphics: gfx,
            baseEnvironment: [:]
        )
        #expect(env(plan, "WINEDEBUG") == LaunchPlanner.logsWineDebug)
        #expect(env(plan, "DXVK_LOG_PATH") == paths.logsDir + "/x")
        #expect(env(plan, "WINEDLLOVERRIDES") == "winemenubuilder.exe=d;d3d11,d3d10core=b")
        #expect(plan.prefix == paths.prefixesDir + "/default")
    }

    @Test func addAppBatReplacesPath() throws {
        let (cfg, paths) = try makeConfig()
        defer { try? FileManager.default.removeItem(atPath: paths.home) }
        var g = Game(gameID: "x", title: "X")
        g.path = "/g/x.exe"
        g.addAppEnabled = true
        g.addAppBat = "/g/both.bat"
        let gfx = GraphicsPlan.resolve(requested: .wined3d, capabilities: fakeRunner().capabilities)
        let plan = try LaunchPlanner.plan(
            game: g,
            config: cfg,
            runner: fakeRunner(),
            paths: paths,
            logs: false,
            graphics: gfx,
            baseEnvironment: [:]
        )
        #expect(plan.argv == [fakeRunner().wineBinary, "cmd", "/c", "/g/both.bat"])
    }

    @Test func errors() throws {
        let (cfg, paths) = try makeConfig()
        defer { try? FileManager.default.removeItem(atPath: paths.home) }
        let gfx = GraphicsPlan.resolve(requested: .wined3d, capabilities: fakeRunner().capabilities)
        let empty = Game(gameID: "x", title: "X")
        #expect(throws: LaunchError.emptyPath) {
            try LaunchPlanner.plan(
                game: empty,
                config: cfg,
                runner: fakeRunner(),
                paths: paths,
                logs: false,
                graphics: gfx,
                baseEnvironment: [:]
            )
        }
        var bad = Game(gameID: "x", title: "X")
        bad.path = "/g/x.exe"
        bad.launchArguments = "FOO='unterminated"
        #expect(throws: LaunchError.self) {
            try LaunchPlanner.plan(
                game: bad,
                config: cfg,
                runner: fakeRunner(),
                paths: paths,
                logs: false,
                graphics: gfx,
                baseEnvironment: [:]
            )
        }
    }

    @Test func globalEnvironmentFile() throws {
        let paths = FaugusPaths(home: NSTemporaryDirectory() + "faugus-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: paths.home) }
        try JSONFile.save(["A=1", "  B = two words ", "bad line", "", "C="], to: paths.envarFile)
        let env = LaunchPlanner.loadGlobalEnvironment(paths: paths)
        #expect(env.map { "\($0.0)|\($0.1)" } == ["A|1", "B|two words", "C|"])
    }

    // MARK: Graphics

    @Test func graphicsRequestFollowsGameThenConfig() throws {
        let (cfg0, paths) = try makeConfig()
        defer { try? FileManager.default.removeItem(atPath: paths.home) }
        var cfg = cfg0
        var g = Game(gameID: "x", title: "X")
        #expect(GraphicsPlan.effectiveRequest(game: g, config: cfg) == .dxvk)
        cfg.setValue("mac-graphics-backend", "wined3d")
        #expect(GraphicsPlan.effectiveRequest(game: g, config: cfg) == .wined3d)
        g.graphics = .wined3dVulkan
        #expect(GraphicsPlan.effectiveRequest(game: g, config: cfg) == .wined3dVulkan)
        g.graphics = .default
        #expect(GraphicsPlan.effectiveRequest(game: g, config: cfg) == .wined3d)
        cfg.setValue("mac-graphics-backend", "default")
        #expect(GraphicsPlan.effectiveRequest(game: g, config: cfg) == .dxvk)
    }

    @Test func graphicsFallbacksUseDetectedCapabilities() {
        let none = RunnerCapabilities()
        let vk = RunnerCapabilities(vulkan: true)
        #expect(GraphicsPlan.resolve(requested: .dxvk, capabilities: none).backend == .wined3d)
        #expect(GraphicsPlan.resolve(requested: .wined3dVulkan, capabilities: none).backend == .wined3d)
        #expect(GraphicsPlan.resolve(requested: .dxvk, capabilities: vk).backend == .dxvk)
        #expect(GraphicsPlan.resolve(requested: .dxmt, capabilities: vk).backend == .dxvk)
        #expect(GraphicsPlan.resolve(requested: .dxmt, capabilities: RunnerCapabilities(dxmt: true)).backend == .dxmt)
        #expect(GraphicsPlan.resolve(requested: .d3dmetal, capabilities: none).backend == .wined3d)
        let plan = GraphicsPlan.resolve(requested: .wined3dVulkan, capabilities: vk)
        #expect(plan.environment == ["WINE_D3D_CONFIG": "renderer=vulkan"])
        #expect(!GraphicsPlan.resolve(requested: .dxmt, capabilities: vk).notes.isEmpty)
    }

    @Test func dllOverrideParsing() {
        let p = DLLOverrides.parse("a,b=n,b;c=d;;bad;e=")
        #expect(p.map { "\($0.dll)=\($0.mode)" } == ["a=n,b", "b=n,b", "c=d", "e="])
        #expect(DLLOverrides.serialize(p) == "a,b=n,b;c=d;e=")
        #expect(DLLOverrides.serialize([]) == "")
    }
}
