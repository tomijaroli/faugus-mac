@testable import FaugusCore
import Foundation
import Testing

@Suite("Launch planning")
struct LaunchPlanTests {
    private func fakeRunner(capabilities: RunnerCapabilities = RunnerCapabilities(
        vulkan: true,
        sdlSupported: true,
        gstreamer: true
    ))
        -> InstalledRunner
    {
        InstalledRunner(
            name: "Wine-Staging-11.21", directory: "/r/Wine-Staging-11.21",
            wineRoot: "/r/Wine-Staging-11.21/Wine Staging.app/Contents/Resources/wine",
            flavor: .staging, version: "11.21", capabilities: capabilities
        )
    }

    private func environmentValue(_ plan: LaunchPlan, _ key: String) -> String? {
        plan.environment[key]
    }

    private func makeConfig() throws -> (FaugusConfig, FaugusPaths) {
        let paths = FaugusPaths(home: NSTemporaryDirectory() + "faugus-plan-\(UUID().uuidString)")
        return try (FaugusConfig.load(paths: paths, language: "en_US"), paths)
    }

    @Test func basicExecutableLaunch() throws {
        let (configuration, paths) = try makeConfig()
        defer { try? FileManager.default.removeItem(atPath: paths.home) }
        var game = Game(gameID: "celeste", title: "Celeste")
        game.path = "/Games/Celeste/Celeste.exe"
        game.prefix = "/Users/u/Faugus/celeste"
        let graphics = GraphicsPlan.resolve(requested: .dxvk, capabilities: fakeRunner().capabilities)
        let plan = try LaunchPlanner.plan(
            game: game, config: configuration, runner: fakeRunner(), paths: paths, logs: false, graphics: graphics,
            baseEnvironment: ["PATH": "/usr/bin", "HOME": "/Users/u"]
        )

        #expect(plan.commandLine == [fakeRunner().wineBinary, "/Games/Celeste/Celeste.exe"])
        #expect(environmentValue(plan, "WINEPREFIX") == "/Users/u/Faugus/celeste")
        #expect(environmentValue(plan, "FAUGUSID") == "celeste")
        #expect(environmentValue(plan, "WINEDEBUG") == "-all")
        #expect(environmentValue(plan, "WINEDLLOVERRIDES") == "winemenubuilder.exe=d;d3d11,d3d10core=n,b")
        #expect(environmentValue(plan, "MVK_CONFIG_RESUME_LOST_DEVICE") == "1")
        #expect(environmentValue(plan, "DXVK_ASYNC") == nil)
        #expect(environmentValue(plan, "PATH")!.hasPrefix(fakeRunner().wineRoot + "/bin:/usr/bin"))
        #expect(plan.logDirectory == paths.logsDirectory + "/celeste")
    }

    @Test func launchSpecByExtension() {
        let wineBinary = "/w/wine"
        #expect(LaunchSpec.command(forPath: "/a/b.exe", wine: wineBinary) == [wineBinary, "/a/b.exe"])
        #expect(LaunchSpec.command(forPath: "/a/b.EXE", wine: wineBinary) == [wineBinary, "/a/b.EXE"])
        #expect(LaunchSpec.command(forPath: "/a/b.msi", wine: wineBinary) == [wineBinary, "msiexec", "/i", "/a/b.msi"])
        #expect(LaunchSpec.command(forPath: "/a/b.bat", wine: wineBinary) == [wineBinary, "cmd", "/c", "/a/b.bat"])
        #expect(LaunchSpec.command(forPath: "/a/b.lnk", wine: wineBinary) == [wineBinary, "start", "/unix", "/a/b.lnk"])
        #expect(LaunchSpec.command(forPath: "/a/b.reg", wine: wineBinary) == [wineBinary, "regedit", "/a/b.reg"])
    }

    @Test func userEnvironmentArgumentsAndPrecedence() throws {
        let (configuration, paths) = try makeConfig()
        defer { try? FileManager.default.removeItem(atPath: paths.home) }
        var game = Game(gameID: "w3", title: "W3")
        game.path = "/g/w3.exe"
        game.prefix = "/p"
        game.launchArguments = #"WINEDLLOVERRIDES="dxgi=n;d3d11=b" FOO=1 BAR="a b" caffeinate -i"#
        game.gameArguments = "-windowed --res='1920 1080'"
        let graphics = GraphicsPlan.resolve(requested: .dxvk, capabilities: fakeRunner().capabilities)
        let plan = try LaunchPlanner.plan(
            game: game, config: configuration, runner: fakeRunner(), paths: paths, logs: false, graphics: graphics,
            globalEnvironment: [("BAR", "global"), ("WINEDEBUG", "err+all")],
            baseEnvironment: [:]
        )

        #expect(plan.commandLine == [
            "caffeinate",
            "-i",
            fakeRunner().wineBinary,
            "/g/w3.exe",
            "-windowed",
            "--res=1920 1080",
        ])
        #expect(environmentValue(plan, "FOO") == "1")
        // Global environmentVariable.json wins over the game's launch_arguments, like upstream.
        #expect(environmentValue(plan, "BAR") == "global")
        #expect(environmentValue(plan, "WINEDEBUG") == "err+all")
        // User override for d3d11 replaces Faugus's; Faugus's d3d10core stays.
        #expect(environmentValue(plan, "WINEDLLOVERRIDES") == "winemenubuilder.exe=d;d3d10core=n,b;dxgi=n;d3d11=b")
    }

    @Test func logsMode() throws {
        let (configuration, paths) = try makeConfig()
        defer { try? FileManager.default.removeItem(atPath: paths.home) }
        var game = Game(gameID: "x", title: "X")
        game.path = "/g/x.exe"
        let graphics = GraphicsPlan.resolve(requested: .wined3d, capabilities: fakeRunner().capabilities)
        let plan = try LaunchPlanner.plan(
            game: game,
            config: configuration,
            runner: fakeRunner(),
            paths: paths,
            logs: true,
            graphics: graphics,
            baseEnvironment: [:]
        )
        #expect(environmentValue(plan, "WINEDEBUG") == LaunchPlanner.logsWineDebug)
        #expect(environmentValue(plan, "DXVK_LOG_PATH") == paths.logsDirectory + "/x")
        #expect(environmentValue(plan, "WINEDLLOVERRIDES") == "winemenubuilder.exe=d;d3d11,d3d10core=b")
        #expect(plan.prefix == paths.prefixesDirectory + "/default")
    }

    @Test func addAppBatReplacesPath() throws {
        let (configuration, paths) = try makeConfig()
        defer { try? FileManager.default.removeItem(atPath: paths.home) }
        var game = Game(gameID: "x", title: "X")
        game.path = "/g/x.exe"
        game.addAppEnabled = true
        game.addAppBat = "/g/both.bat"
        let graphics = GraphicsPlan.resolve(requested: .wined3d, capabilities: fakeRunner().capabilities)
        let plan = try LaunchPlanner.plan(
            game: game,
            config: configuration,
            runner: fakeRunner(),
            paths: paths,
            logs: false,
            graphics: graphics,
            baseEnvironment: [:]
        )
        #expect(plan.commandLine == [fakeRunner().wineBinary, "cmd", "/c", "/g/both.bat"])
    }

    @Test func errors() throws {
        let (configuration, paths) = try makeConfig()
        defer { try? FileManager.default.removeItem(atPath: paths.home) }
        let graphics = GraphicsPlan.resolve(requested: .wined3d, capabilities: fakeRunner().capabilities)
        let empty = Game(gameID: "x", title: "X")
        #expect(throws: LaunchError.emptyPath) {
            try LaunchPlanner.plan(
                game: empty,
                config: configuration,
                runner: fakeRunner(),
                paths: paths,
                logs: false,
                graphics: graphics,
                baseEnvironment: [:]
            )
        }
        var bad = Game(gameID: "x", title: "X")
        bad.path = "/g/x.exe"
        bad.launchArguments = "FOO='unterminated"
        #expect(throws: LaunchError.self) {
            try LaunchPlanner.plan(
                game: bad,
                config: configuration,
                runner: fakeRunner(),
                paths: paths,
                logs: false,
                graphics: graphics,
                baseEnvironment: [:]
            )
        }
    }

    @Test func globalEnvironmentFile() throws {
        let paths = FaugusPaths(home: NSTemporaryDirectory() + "faugus-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: paths.home) }
        try JSONFile.save(["A=1", "  B = two words ", "bad line", "", "C="], to: paths.environmentVariablesFile)
        let globalEnvironment = LaunchPlanner.loadGlobalEnvironment(paths: paths)
        #expect(globalEnvironment.map { "\($0.0)|\($0.1)" } == ["A|1", "B|two words", "C|"])
    }

    // MARK: Graphics

    @Test func graphicsRequestFollowsGameThenConfig() throws {
        let (loadedConfiguration, paths) = try makeConfig()
        defer { try? FileManager.default.removeItem(atPath: paths.home) }
        var configuration = loadedConfiguration
        var game = Game(gameID: "x", title: "X")
        #expect(GraphicsPlan.effectiveRequest(game: game, config: configuration) == .dxvk)
        configuration.setValue("mac-graphics-backend", "wined3d")
        #expect(GraphicsPlan.effectiveRequest(game: game, config: configuration) == .wined3d)
        game.graphics = .wined3dVulkan
        #expect(GraphicsPlan.effectiveRequest(game: game, config: configuration) == .wined3dVulkan)
        game.graphics = .default
        #expect(GraphicsPlan.effectiveRequest(game: game, config: configuration) == .wined3d)
        configuration.setValue("mac-graphics-backend", "default")
        #expect(GraphicsPlan.effectiveRequest(game: game, config: configuration) == .dxvk)
    }

    @Test func graphicsFallbacksUseDetectedCapabilities() {
        let none = RunnerCapabilities()
        let vulkanCapabilities = RunnerCapabilities(vulkan: true)
        #expect(GraphicsPlan.resolve(requested: .dxvk, capabilities: none).backend == .wined3d)
        #expect(GraphicsPlan.resolve(requested: .wined3dVulkan, capabilities: none).backend == .wined3d)
        #expect(GraphicsPlan.resolve(requested: .dxvk, capabilities: vulkanCapabilities).backend == .dxvk)
        #expect(GraphicsPlan.resolve(requested: .dxmt, capabilities: vulkanCapabilities).backend == .dxvk)
        #expect(GraphicsPlan.resolve(requested: .dxmt, capabilities: RunnerCapabilities(dxmt: true)).backend == .dxmt)
        #expect(GraphicsPlan.resolve(requested: .d3dmetal, capabilities: none).backend == .wined3d)
        let plan = GraphicsPlan.resolve(requested: .wined3dVulkan, capabilities: vulkanCapabilities)
        #expect(plan.environment == ["WINE_D3D_CONFIG": "renderer=vulkan"])
        #expect(!GraphicsPlan.resolve(requested: .dxmt, capabilities: vulkanCapabilities).notes.isEmpty)
    }

    @Test func dllOverrideParsing() {
        let overrides = DLLOverrides.parse("a,b=n,b;c=d;;bad;e=")
        #expect(overrides.map { "\($0.dll)=\($0.mode)" } == ["a=n,b", "b=n,b", "c=d", "e="])
        #expect(DLLOverrides.serialize(overrides) == "a,b=n,b;c=d;e=")
        #expect(DLLOverrides.serialize([]) == "")
    }
}
