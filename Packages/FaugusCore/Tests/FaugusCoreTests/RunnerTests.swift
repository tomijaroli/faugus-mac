import Foundation
import Testing

@testable import FaugusCore

@Suite("Runner catalog and installer")
struct RunnerTests {
    @Test func versionOrdering() {
        let sorted = ["11.21", "11.6_1", "11.0_1", "11.7", "11.18", "10.20", "11.9"].sorted { VersionKey($0) < VersionKey($1) }
        #expect(sorted == ["10.20", "11.0_1", "11.6_1", "11.7", "11.9", "11.18", "11.21"])
        #expect(VersionKey("11.0") < VersionKey("11.0_1"))
        #expect(VersionKey("11.0-rc1") < VersionKey("11.0"))
    }

    @Test func parsesRealGcenxFeed() throws {
        let json = try JSONParser.parse(try TestSupport.fixtureData("gcenx-releases.json"))
        let runners = GcenxFeed.parse(json)
        #expect(!runners.isEmpty)
        #expect(Set(runners.map(\.flavor)) == [.staging, .devel, .stable])

        let latestStaging = GcenxFeed.latest(.staging, in: runners)!
        #expect(latestStaging.version == "11.21")
        #expect(latestStaging.assetName == "wine-staging-11.21-osx64.tar.xz")
        #expect(latestStaging.directoryName == "Wine-Staging-11.21")
        #expect(latestStaging.sha256?.count == 64)
        #expect(latestStaging.downloadURL.absoluteString.hasSuffix("/11.21/wine-staging-11.21-osx64.tar.xz"))

        let stable = GcenxFeed.latest(.stable, in: runners)!
        #expect(stable.version == "11.0_1")
        #expect(stable.directoryName == "Wine-Stable-11.0_1")
    }

    @Test func ignoresDraftsPrereleasesAndForeignAssets() {
        let json: JSONValue = [
            ["tag_name": "1.0", "draft": true, "assets": [["name": "wine-staging-1.0-osx64.tar.xz", "browser_download_url": "https://x/a"]]],
            ["tag_name": "2.0", "prerelease": true, "assets": [["name": "wine-staging-2.0-osx64.tar.xz", "browser_download_url": "https://x/b"]]],
            ["tag_name": "3.0", "assets": [
                ["name": "README.txt", "browser_download_url": "https://x/c"],
                ["name": "wine-staging-3.0-osx64.tar.xz", "browser_download_url": "https://x/d", "size": 5, "digest": "sha256:abc"],
            ]],
        ]
        let runners = GcenxFeed.parse(json)
        #expect(runners.map(\.version) == ["3.0"])
        #expect(runners[0].sha256 == "abc")
    }

    // MARK: Archive safety

    @Test func rejectsUnsafeMemberNames() {
        #expect(throws: RunnerError.self) { try ArchiveSafety.validate(memberNames: ["/etc/passwd"]) }
        #expect(throws: RunnerError.self) { try ArchiveSafety.validate(memberNames: ["a/../../b"]) }
        #expect(throws: RunnerError.self) { try ArchiveSafety.validate(memberNames: ["../x"]) }
        #expect(throws: RunnerError.self) { try ArchiveSafety.validate(memberNames: ["~/x"]) }
        #expect(throws: Never.self) { try ArchiveSafety.validate(memberNames: ["Wine Staging.app/Contents/..hidden", "a/b/c", "a/"]) }
    }

    @Test func rejectsEscapingSymlinks() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        let root = paths.home + "/tree"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/a/b", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: root + "/a/ok", withDestinationPath: "b")
        try fm.createSymbolicLink(atPath: root + "/a/b/up", withDestinationPath: "../b")
        #expect(throws: Never.self) { try ArchiveSafety.validateTree(root: root) }

        try fm.createSymbolicLink(atPath: root + "/a/escape", withDestinationPath: "../../outside")
        #expect(throws: RunnerError.self) { try ArchiveSafety.validateTree(root: root) }
        try fm.removeItem(atPath: root + "/a/escape")
        try fm.createSymbolicLink(atPath: root + "/abs", withDestinationPath: "/etc")
        #expect(throws: RunnerError.self) { try ArchiveSafety.validateTree(root: root) }
    }

    // MARK: Store

    /// Builds a fake runner tree shaped like a Gcenx archive.
    private func makeFakeRunnerTarball(in dir: String, flavorApp: String = "Wine Staging") throws -> String {
        let fm = FileManager.default
        let src = dir + "/src"
        let wine = src + "/\(flavorApp).app/Contents/Resources/wine"
        try fm.createDirectory(atPath: wine + "/bin", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: wine + "/lib/GStreamer.framework", withIntermediateDirectories: true)
        for exe in ["wine", "wineserver"] {
            try Data("#!/bin/sh\necho fake-\(exe)\n".utf8).write(to: URL(fileURLWithPath: wine + "/bin/" + exe))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine + "/bin/" + exe)
        }
        for lib in ["libMoltenVK.dylib", "libvulkan.dylib", "libSDL2.dylib"] {
            try Data().write(to: URL(fileURLWithPath: wine + "/lib/" + lib))
        }
        let tar = dir + "/fake.tar.xz"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-cJf", tar, "-C", src, "."]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        return tar
    }

    @Test func installsExtractsAndDetectsCapabilities() async throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        let tar = try makeFakeRunnerTarball(in: paths.home)
        let installer = RunnerInstaller(paths: paths)
        let runner = try await installer.installArchive(at: tar, directoryName: "Wine-Staging-11.21", sourceTag: "11.21")

        #expect(runner.name == "Wine-Staging-11.21")
        #expect(runner.flavor == .staging)
        #expect(runner.version == "11.21")
        #expect(runner.wineRoot.hasSuffix("Wine Staging.app/Contents/Resources/wine"))
        #expect(FileManager.default.isExecutableFile(atPath: runner.wineBinary))
        #expect(runner.capabilities == RunnerCapabilities(vulkan: true, sdl: true, gstreamer: true))
        #expect(FileManager.default.fileExists(atPath: runner.directory + "/.faugus-install.json"))
        // No staging leftovers.
        let entries = try FileManager.default.contentsOfDirectory(atPath: paths.runnersDir)
        #expect(entries == ["Wine-Staging-11.21"])
    }

    @Test func manifestDeclaresDXMTAndD3DMetalOnly() async throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        let tar = try makeFakeRunnerTarball(in: paths.home)
        let runner = try await RunnerInstaller(paths: paths).installArchive(at: tar, directoryName: "Wine-Devel-1.0")
        #expect(!runner.capabilities.dxmt)
        try JSONFile.save(["dxmt": true], to: runner.directory + "/faugus-runner.json")
        let reread = RunnerStore(paths: paths).find(name: "Wine-Devel-1.0")!
        #expect(reread.capabilities.dxmt)
        #expect(!reread.capabilities.d3dmetal)
    }

    @Test func refusesArchiveWithoutWine() async throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        let src = paths.home + "/src"
        try FileManager.default.createDirectory(atPath: src + "/x", withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: URL(fileURLWithPath: src + "/x/readme"))
        let tar = paths.home + "/nowine.tar.xz"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-cJf", tar, "-C", src, "."]
        try p.run(); p.waitUntilExit()

        await #expect(throws: RunnerError.self) {
            try await RunnerInstaller(paths: paths).installArchive(at: tar, directoryName: "Wine-Staging-1")
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: paths.runnersDir)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func refusesArchiveWithEscapingSymlink() async throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        let tar0 = try makeFakeRunnerTarball(in: paths.home)
        _ = tar0
        try FileManager.default.createSymbolicLink(
            atPath: paths.home + "/src/evil", withDestinationPath: "../../../../etc")
        let tar = paths.home + "/evil.tar.xz"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-cJf", tar, "-C", paths.home + "/src", "."]
        try p.run(); p.waitUntilExit()

        await #expect(throws: RunnerError.self) {
            try await RunnerInstaller(paths: paths).installArchive(at: tar, directoryName: "Wine-Staging-2")
        }
        #expect(RunnerStore(paths: paths).installed().isEmpty)
    }

    @Test func resolution() async throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        let store = RunnerStore(paths: paths)
        #expect(store.resolve("Default", defaultRunner: "Wine-Staging Latest") == .missingLatest(.staging))
        #expect(store.resolve("Foo", defaultRunner: "Wine-Staging Latest") == .missing("Foo"))

        let tar = try makeFakeRunnerTarball(in: paths.home)
        let installer = RunnerInstaller(paths: paths)
        _ = try await installer.installArchive(at: tar, directoryName: "Wine-Staging-11.9")
        _ = try await installer.installArchive(at: tar, directoryName: "Wine-Staging-11.21")
        _ = try await installer.installArchive(at: tar, directoryName: "Wine-Devel-11.30")

        guard case .installed(let latest) = store.resolve("Default", defaultRunner: "Wine-Staging Latest") else {
            Issue.record("expected installed"); return
        }
        #expect(latest.name == "Wine-Staging-11.21")
        guard case .installed(let exact) = store.resolve("Wine-Staging-11.9", defaultRunner: "x") else {
            Issue.record("expected installed"); return
        }
        #expect(exact.version == "11.9")
        #expect(store.resolve("Wine-Stable Latest", defaultRunner: "x") == .missingLatest(.stable))
        #expect(store.installed().map(\.name) == ["Wine-Devel-11.30", "Wine-Staging-11.21", "Wine-Staging-11.9"])
        #expect(store.find(name: "../etc") == nil)

        try installer.uninstall(name: "Wine-Staging-11.9")
        #expect(store.find(name: "Wine-Staging-11.9") == nil)
    }

    @Test func rosettaScriptShape() {
        #expect(Rosetta.installAppleScript == "do shell script \"/usr/sbin/softwareupdate --install-rosetta --agree-to-license\" with administrator privileges")
    }
}
