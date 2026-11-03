@testable import FaugusCore
import Foundation
import Testing

@Suite("Winetricks")
struct WinetricksTests {
    private func runner(_ paths: FaugusPaths) -> InstalledRunner {
        InstalledRunner(
            name: "Wine-Staging-11.21", directory: paths.runnersDirectory + "/Wine-Staging-11.21",
            wineRoot: paths.runnersDirectory + "/Wine-Staging-11.21", flavor: .staging, version: "11.21",
            capabilities: .init()
        )
    }

    @Test func parsesTheRealListAll() throws {
        let text = try String(decoding: TestSupport.fixtureData("winetricks-list-all.txt"), as: UTF8.self)
        let cats = Winetricks.parseList(text)
        #expect(cats.map(\.name) == ["apps", "benchmarks", "dlls", "fonts", "settings"])
        let dlls = try #require(cats.first { $0.name == "dlls" })
        let vcrun = try #require(dlls.verbs.first { $0.name == "vcrun2022" })
        #expect(vcrun.summary.contains("Visual C++"))
        #expect(vcrun.category == "dlls")
        // Output noise is not a verb, and settings keep their `=` names.
        #expect(!cats.flatMap(\.verbs).contains { $0.name.hasPrefix("Executing") || $0.name.hasPrefix("warning") })
        #expect(cats.first { $0.name == "settings" }!.verbs
            .contains { $0.name == "vd=1024x768" || $0.name == "alldlls=builtin" })
        // `winver=` (empty value) and the `prefix` meta-verbs are left out.
        #expect(!cats.flatMap(\.verbs).contains { $0.name.hasSuffix("=") })
        #expect(cats.flatMap(\.verbs).count > 400)
    }

    @Test func readsInstalledVerbsFromThePrefixLog() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        let prefix = paths.home + "/pfx"
        try FileManager.default.createDirectory(atPath: prefix, withIntermediateDirectories: true)
        try "corefonts\nvcrun2022\n\n  d3dx9 \n".write(
            toFile: prefix + "/winetricks.log",
            atomically: true,
            encoding: .utf8
        )
        #expect(Winetricks.installedVerbs(prefix: prefix) == ["corefonts", "vcrun2022", "d3dx9"])
        #expect(Winetricks.installedVerbs(prefix: paths.home + "/missing").isEmpty)
    }

    @Test func invocationUsesTheRunnerAndASharedCache() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        let r = runner(paths)
        let inv = WinetricksInvocation.install(
            verbs: ["vcrun2022", "corefonts"], prefix: "/p/game", runner: r, paths: paths, logName: "my-game",
            base: ["PATH": "/usr/bin:/bin", "HOME": paths.home]
        )
        #expect(inv.argv.first == "/bin/sh")
        #expect(inv.argv.suffix(3) == ["-q", "vcrun2022", "corefonts"])
        #expect(inv.argv[1] == WinetricksComponent(paths: paths).scriptPath)
        #expect(inv.environment["WINEPREFIX"] == "/p/game")
        #expect(inv.environment["WINE"] == r.wineBinary)
        #expect(inv.environment["WINESERVER"] == r.wineserverBinary)
        #expect(inv.environment["W_CACHE"] == paths.winetricksDirectory + "/cache")
        #expect(inv.environment["WINETRICKS_LATEST_VERSION_CHECK"] == "disabled")
        let path = inv.environment["PATH"] ?? ""
        #expect(path.hasPrefix(r.wineRoot + "/bin:"))
        #expect(path.contains("/opt/homebrew/bin"))
        #expect(inv.logFile == paths.logsDirectory + "/my-game/winetricks.log")
        // Nothing of the runner is written: the script, cache and log live elsewhere.
        #expect(!inv.logFile.hasPrefix(r.directory) && !inv.environment["W_CACHE", default: ""].hasPrefix(r.directory))
    }

    @Test func installScriptChecksTheHashAndMakesItExecutable() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        let src = paths.home + "/src-winetricks"
        try "#!/bin/sh\necho hi\n".write(toFile: src, atomically: true, encoding: .utf8)
        let component = WinetricksComponent(paths: paths)
        #expect(!component.isInstalled)
        #expect(throws: RunnerError.self) { try component.installScript(
            at: src,
            expectedSHA256: String(repeating: "0", count: 64)
        ) }
        #expect(!component.isInstalled)
        try component.installScript(at: src, expectedSHA256: Downloader.sha256(ofFileAt: src))
        #expect(component.isInstalled)
        #expect(FileManager.default.isExecutableFile(atPath: component.scriptPath))
    }

    @Test func logTailReturnsOnlyCompleteLinesAndCarriageReturns() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        let file = paths.home + "/t.log"
        FileManager.default.createFile(atPath: file, contents: nil)
        let tail = LogTail(path: file)
        func append(_ s: String) throws {
            let h = try FileHandle(forWritingTo: URL(fileURLWithPath: file))
            try h.seekToEnd()
            try h.write(contentsOf: Data(s.utf8))
            try h.close()
        }
        try append("one\ntw")
        #expect(tail.poll() == ["one"])
        try append("o\r 10%\r 20%\nlast")
        #expect(tail.poll() == ["two", " 10%", " 20%"])
        #expect(tail.poll().isEmpty)
        #expect(tail.poll(flush: true) == ["last"])
    }

    @Test func aFakeScriptRunsInThePrefixAndItsOutputReachesTheLog() async throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        let component = WinetricksComponent(paths: paths)
        let src = paths.home + "/fake"
        try """
        #!/bin/sh
        echo "args: $@"
        echo "prefix: $WINEPREFIX"
        echo "cache: $W_CACHE"
        echo "pwd: $(pwd)"
        echo "$2" >> "$WINEPREFIX/winetricks.log"
        exit 0
        """.write(toFile: src, atomically: true, encoding: .utf8)
        try component.installScript(at: src, expectedSHA256: nil)
        let prefix = paths.home + "/pfx"
        try FileManager.default.createDirectory(atPath: prefix, withIntermediateDirectories: true)
        let inv = WinetricksInvocation.install(
            verbs: ["corefonts"],
            prefix: prefix,
            runner: runner(paths),
            paths: paths,
            logName: "fake"
        )
        let pid = try ProcessSpawner.spawn(
            argv: inv.argv,
            options: .init(
                workingDirectory: inv.workingDirectory,
                environment: inv.environment,
                outputFile: inv.logFile
            )
        )
        let status = await ProcessSpawner.waitForExit(pid: pid)
        #expect(status == 0)
        let lines = LogTail(path: inv.logFile).poll(flush: true)
        #expect(lines.contains("args: -q corefonts"))
        #expect(lines.contains("prefix: \(prefix)"))
        #expect(lines.contains("cache: \(paths.winetricksDirectory)/cache"))
        #expect(Winetricks.installedVerbs(prefix: prefix) == ["corefonts"])
    }
}
