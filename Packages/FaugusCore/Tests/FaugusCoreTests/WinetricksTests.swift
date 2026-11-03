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
        let categories = Winetricks.parseList(text)
        #expect(categories.map(\.name) == ["apps", "benchmarks", "dlls", "fonts", "settings"])
        let dlls = try #require(categories.first { $0.name == "dlls" })
        let vcrun = try #require(dlls.verbs.first { $0.name == "vcrun2022" })
        #expect(vcrun.summary.contains("Visual C++"))
        #expect(vcrun.category == "dlls")
        // Output noise is not a verb, and settings keep their `=` names.
        #expect(!categories.flatMap(\.verbs)
            .contains { $0.name.hasPrefix("Executing") || $0.name.hasPrefix("warning") })
        #expect(categories.first { $0.name == "settings" }!.verbs
            .contains { $0.name == "vd=1024x768" || $0.name == "alldlls=builtin" })
        // `winver=` (empty value) and the `prefix` meta-verbs are left out.
        #expect(!categories.flatMap(\.verbs).contains { $0.name.hasSuffix("=") })
        #expect(categories.flatMap(\.verbs).count > 400)
    }

    @Test func readsInstalledVerbsFromThePrefixLog() throws {
        let paths = try TestSupport.makeTemporaryHome()
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
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        let installedRunner = runner(paths)
        let invocation = WinetricksInvocation.install(
            verbs: ["vcrun2022", "corefonts"], prefix: "/p/game", runner: installedRunner, paths: paths,
            logName: "my-game",
            base: ["PATH": "/usr/bin:/bin", "HOME": paths.home]
        )
        #expect(invocation.commandLine.first == "/bin/sh")
        #expect(invocation.commandLine.suffix(3) == ["-q", "vcrun2022", "corefonts"])
        #expect(invocation.commandLine[1] == WinetricksComponent(paths: paths).scriptPath)
        #expect(invocation.environment["WINEPREFIX"] == "/p/game")
        #expect(invocation.environment["WINE"] == installedRunner.wineBinary)
        #expect(invocation.environment["WINESERVER"] == installedRunner.wineserverBinary)
        #expect(invocation.environment["W_CACHE"] == paths.winetricksDirectory + "/cache")
        #expect(invocation.environment["WINETRICKS_LATEST_VERSION_CHECK"] == "disabled")
        let path = invocation.environment["PATH"] ?? ""
        #expect(path.hasPrefix(installedRunner.wineRoot + "/bin:"))
        #expect(path.contains("/opt/homebrew/bin"))
        #expect(invocation.logFile == paths.logsDirectory + "/my-game/winetricks.log")
        // Nothing of the runner is written: the script, cache and log live elsewhere.
        #expect(!invocation.logFile.hasPrefix(installedRunner.directory) && !invocation.environment[
            "W_CACHE",
            default: ""
        ].hasPrefix(installedRunner.directory))
    }

    @Test func installScriptChecksTheHashAndMakesItExecutable() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        let scriptSourcePath = paths.home + "/src-winetricks"
        try "#!/bin/sh\necho hi\n".write(toFile: scriptSourcePath, atomically: true, encoding: .utf8)
        let component = WinetricksComponent(paths: paths)
        #expect(!component.isInstalled)
        #expect(throws: RunnerError.self) { try component.installScript(
            at: scriptSourcePath,
            expectedSHA256: String(repeating: "0", count: 64)
        ) }
        #expect(!component.isInstalled)
        try component.installScript(at: scriptSourcePath, expectedSHA256: Downloader.sha256(ofFileAt: scriptSourcePath))
        #expect(component.isInstalled)
        #expect(FileManager.default.isExecutableFile(atPath: component.scriptPath))
    }

    @Test func logTailReturnsOnlyCompleteLinesAndCarriageReturns() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        let file = paths.home + "/t.log"
        FileManager.default.createFile(atPath: file, contents: nil)
        let tail = LogTail(path: file)
        func append(_ text: String) throws {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        }
        try append("one\ntw")
        #expect(tail.poll() == ["one"])
        try append("o\r 10%\r 20%\nlast")
        #expect(tail.poll() == ["two", " 10%", " 20%"])
        #expect(tail.poll().isEmpty)
        #expect(tail.poll(flush: true) == ["last"])
    }

    @Test func aFakeScriptRunsInThePrefixAndItsOutputReachesTheLog() async throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        let component = WinetricksComponent(paths: paths)
        let scriptSourcePath = paths.home + "/fake"
        try """
        #!/bin/sh
        echo "args: $@"
        echo "prefix: $WINEPREFIX"
        echo "cache: $W_CACHE"
        echo "pwd: $(pwd)"
        echo "$2" >> "$WINEPREFIX/winetricks.log"
        exit 0
        """.write(toFile: scriptSourcePath, atomically: true, encoding: .utf8)
        try component.installScript(at: scriptSourcePath, expectedSHA256: nil)
        let prefix = paths.home + "/pfx"
        try FileManager.default.createDirectory(atPath: prefix, withIntermediateDirectories: true)
        let invocation = WinetricksInvocation.install(
            verbs: ["corefonts"],
            prefix: prefix,
            runner: runner(paths),
            paths: paths,
            logName: "fake"
        )
        let pid = try ProcessSpawner.spawn(
            commandLine: invocation.commandLine,
            options: .init(
                workingDirectory: invocation.workingDirectory,
                environment: invocation.environment,
                outputFile: invocation.logFile
            )
        )
        let status = await ProcessSpawner.waitForExit(pid: pid)
        #expect(status == 0)
        let lines = LogTail(path: invocation.logFile).poll(flush: true)
        #expect(lines.contains("args: -q corefonts"))
        #expect(lines.contains("prefix: \(prefix)"))
        #expect(lines.contains("cache: \(paths.winetricksDirectory)/cache"))
        #expect(Winetricks.installedVerbs(prefix: prefix) == ["corefonts"])
    }
}
