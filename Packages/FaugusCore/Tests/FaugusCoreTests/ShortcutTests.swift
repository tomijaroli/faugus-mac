import CoreGraphics
@testable import FaugusCore
import Foundation
import ImageIO
import Testing

@Suite("Shortcuts")
struct ShortcutsTests {
    // MARK: Fixtures

    private struct Environment {
        let paths: FaugusPaths
        let fakeFaugusPath: String
        let dumpPath: String
        let iconPath: String
        let fallbackIconPath: String
        let shortcuts: GameShortcuts
        let library: ShortcutLibrary

        var applicationsDirectory: String {
            paths.userApplicationsShortcutsDirectory
        }

        var desktopDirectory: String {
            paths.desktopDirectory
        }
    }

    private static func writePNG(side: Int, to path: String) throws {
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = try #require(context.makeImage())
        let data = try #require(ImageTools.png(image))
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// A fake Faugus binary that dumps its working directory, argv and three environment
    /// variables as NUL-terminated records.
    private static func writeFakeFaugus(at path: String, dumpPath: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        let script = """
        #!/bin/sh
        printf '%s\\0' "$(pwd -P)" "$@" "$PROTON_PREFER_SDL" "$NO_SLEEP" "$CUSTOM_VARIABLE" > \
        \(ShellWords.quote(dumpPath))
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    private static func makeEnvironment(
        fakeFaugusDirectoryName: String = "bin"
    ) throws -> Environment {
        let paths = try TestSupport.makeTemporaryHome()
        let fakeFaugusPath = paths.home + "/" + fakeFaugusDirectoryName + "/Faugus"
        let dumpPath = paths.home + "/dump.bin"
        try writeFakeFaugus(at: fakeFaugusPath, dumpPath: dumpPath)
        let iconPath = paths.home + "/source-icon.png"
        let fallbackIconPath = paths.home + "/fallback-icon.png"
        try writePNG(side: 1024, to: iconPath)
        try writePNG(side: 256, to: fallbackIconPath)
        let shortcuts = GameShortcuts(paths: paths, executablePath: fakeFaugusPath, fallbackIconPath: fallbackIconPath)
        let library = ShortcutLibrary(paths: paths, executablePath: fakeFaugusPath, fallbackIconPath: fallbackIconPath)
        return Environment(
            paths: paths, fakeFaugusPath: fakeFaugusPath, dumpPath: dumpPath, iconPath: iconPath,
            fallbackIconPath: fallbackIconPath, shortcuts: shortcuts, library: library
        )
    }

    private static func makeGame(
        _ gameID: String, title: String, directory: String? = nil
    ) -> Game {
        var game = Game(gameID: gameID, title: title)
        if let directory {
            game.path = directory + "/game.exe"
        }
        return game
    }

    /// Runs a bundle's `launch` script and returns the dump written by the fake Faugus.
    private static func runLaunchScript(of bundlePath: String, dumpPath: String) throws -> [String] {
        try? FileManager.default.removeItem(atPath: dumpPath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bundlePath + "/" + ShortcutBundle.launchScriptRelativePath)
        process.environment = ["PATH": "/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let data = try Data(contentsOf: URL(fileURLWithPath: dumpPath))
        var records = data.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        records.removeLast() // Text after the final terminator.
        return records
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func bundleNames(in directory: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
    }

    private static func makeForeignBundle(at bundlePath: String) throws {
        try FileManager.default.createDirectory(
            atPath: bundlePath + "/Contents/MacOS", withIntermediateDirectories: true
        )
        try "foreign".write(toFile: bundlePath + "/Contents/Info.plist", atomically: true, encoding: .utf8)
    }
}

extension ShortcutsTests {
    // MARK: Bundle structure

    @Test func writesTheBundleStructureAndInfoPlist() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        let game = Self.makeGame("my-game", title: "My Game", directory: environment.paths.home + "/games")

        let installed = try environment.shortcuts.install(
            for: game, locations: [.applicationsMenu], iconPath: environment.iconPath
        )

        let bundlePath = environment.applicationsDirectory + "/My Game.app"
        #expect(installed == [.applicationsMenu: bundlePath])
        #expect(!FileManager.default.fileExists(atPath: environment.desktopDirectory + "/My Game.app"))
        for relativePath in [
            ShortcutBundle.infoPropertyListRelativePath, ShortcutBundle.launchScriptRelativePath,
            ShortcutBundle.iconRelativePath, ShortcutBundle.markerRelativePath,
        ] {
            #expect(FileManager.default.fileExists(atPath: bundlePath + "/" + relativePath), "\(relativePath)")
        }

        let plistData = try Data(contentsOf: URL(fileURLWithPath: bundlePath + "/Contents/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        )
        #expect(plist["CFBundleName"] as? String == "My Game")
        #expect(plist["CFBundleDisplayName"] as? String == "My Game")
        #expect(plist["CFBundleExecutable"] as? String == "launch")
        #expect(plist["CFBundleIdentifier"] as? String == "me.tomijaroli.faugus-mac.shortcut.my-game")
        #expect(plist["CFBundlePackageType"] as? String == "APPL")
        #expect(plist["CFBundleIconFile"] as? String == "AppIcon")
        #expect(plist["NSHighResolutionCapable"] as? Bool == true)
        #expect(plist["LSUIElement"] == nil)

        let markerData =
            try Data(contentsOf: URL(fileURLWithPath: bundlePath + "/" + ShortcutBundle.markerRelativePath))
        let marker = try #require(JSONParser.parse(markerData).objectValue)
        #expect(marker["gameid"]?.stringValue == "my-game")
        #expect(marker["kind"]?.stringValue == "game")
        #expect(ShortcutBundle.marker(atBundlePath: bundlePath) == ShortcutMarker(gameID: "my-game", kind: .game))
    }

    @Test func launchScriptIsExecutable() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        let game = Self.makeGame("run-me", title: "Run Me")
        try environment.shortcuts.install(for: game, locations: [.desktop])

        let scriptPath = environment.desktopDirectory + "/Run Me.app/" + ShortcutBundle.launchScriptRelativePath
        let attributes = try FileManager.default.attributesOfItem(atPath: scriptPath)
        #expect((attributes[.posixPermissions] as? Int) == 0o755)
        #expect(FileManager.default.isExecutableFile(atPath: scriptPath))
        let script = try String(contentsOfFile: scriptPath, encoding: .utf8)
        #expect(script.hasPrefix("#!/bin/sh\n"))
    }

    @Test func gameLaunchIsFaugusDashDashGameFromTheGameFolder() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        let gameDirectory = environment.paths.home + "/games/Some Game"
        try FileManager.default.createDirectory(atPath: gameDirectory, withIntermediateDirectories: true)
        let game = Self.makeGame("some-game", title: "Some Game", directory: gameDirectory)

        let launch = environment.shortcuts.launch(for: game)
        #expect(launch.executablePath == environment.fakeFaugusPath)
        #expect(launch.workingDirectory == gameDirectory)
        #expect(LaunchMode.parse(launch.arguments) == .runGame(
            id: "some-game",
            logs: false,
            preLaunch: "",
            postLaunch: ""
        ))

        try environment.shortcuts.install(for: game, locations: [.desktop])
        let dump = try Self.runLaunchScript(
            of: environment.desktopDirectory + "/Some Game.app", dumpPath: environment.dumpPath
        )
        #expect(dump == [Self.realPath(gameDirectory), "--game", "some-game", "", "", ""])
    }
}

extension ShortcutsTests {
    // MARK: Script quoting

    @Test func hostileLaunchDataReachesTheExecutableUnchanged() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        let hostileFolder = environment.paths.home + "/it's a \"dir\" $HOME `id` & ; (x)"
        let hostileExecutable = hostileFolder + "/Faugus $PATH 'x'"
        try Self.writeFakeFaugus(at: hostileExecutable, dumpPath: environment.dumpPath)
        let hostileWorkingDirectory = hostileFolder + "/work $(touch pwned) \\ dir"
        try FileManager.default.createDirectory(atPath: hostileWorkingDirectory, withIntermediateDirectories: true)

        let hostileArguments = [
            "--game", "it's \"quoted\" $HOME $(touch pwned) `touch pwned` \\ ; & | > < *",
            "", "two words", "line one\nline two", "-n", "--", "~",
        ]
        let launch = ShortcutLaunch(
            executablePath: hostileExecutable,
            arguments: hostileArguments,
            workingDirectory: hostileWorkingDirectory,
            environment: [
                ShortcutEnvironmentVariable(name: "CUSTOM_VARIABLE", value: "va'lue \"x\" $HOME `y`"),
                ShortcutEnvironmentVariable(name: "PROTON_PREFER_SDL", value: "1"),
                ShortcutEnvironmentVariable(name: "not a name", value: "ignored"),
            ]
        )
        let bundlePath = environment.paths.home + "/Hostile \"Title\" $HOME 'x'.app"
        try ShortcutBundle.write(
            at: bundlePath, title: "Hostile \"Title\" $HOME 'x'",
            marker: ShortcutMarker(gameID: "hostile", kind: .game), launch: launch,
            iconPath: nil, fallbackIconPath: environment.fallbackIconPath
        )

        let dump = try Self.runLaunchScript(of: bundlePath, dumpPath: environment.dumpPath)
        #expect(dump == [Self.realPath(hostileWorkingDirectory)] + hostileArguments + [
            "1",
            "",
            "va'lue \"x\" $HOME `y`",
        ])
        #expect(!FileManager.default.fileExists(atPath: hostileWorkingDirectory + "/pwned"))
        #expect(!FileManager.default.fileExists(atPath: environment.paths.home + "/pwned"))
    }

    @Test func missingWorkingDirectoryIsSkipped() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        let game = Self.makeGame("gone", title: "Gone", directory: environment.paths.home + "/does/not/exist")
        try environment.shortcuts.install(for: game, locations: [.desktop])

        let script = try String(
            contentsOfFile: environment.desktopDirectory + "/Gone.app/" + ShortcutBundle.launchScriptRelativePath,
            encoding: .utf8
        )
        #expect(script.contains("if [ -d "))
        let dump = try Self.runLaunchScript(
            of: environment.desktopDirectory + "/Gone.app",
            dumpPath: environment.dumpPath
        )
        #expect(dump.dropFirst().first == "--game")
    }

    @Test func hostileTitleKeepsItsVerbatimDisplayNameAndASafeFileName() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        let title = ".. Evil/Title: \"x\" $HOME 'y'\u{7}\n"
        let game = Self.makeGame("evil", title: title)

        let installed = try environment.shortcuts.install(for: game, locations: [.desktop])
        let bundlePath = try #require(installed[.desktop])
        #expect((bundlePath as NSString).deletingLastPathComponent == environment.desktopDirectory)
        #expect((bundlePath as NSString).lastPathComponent == "EvilTitle \"x\" $HOME 'y'.app")

        let plistData = try Data(contentsOf: URL(fileURLWithPath: bundlePath + "/Contents/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        )
        #expect(plist["CFBundleDisplayName"] as? String == title)
    }
}

extension ShortcutsTests {
    // MARK: Icon

    private static func icnsPixelWidths(_ data: Data) -> Set<Int> {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
        var widths: Set<Int> = []
        for frameIndex in 0 ..< CGImageSourceGetCount(source) {
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, frameIndex, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int
            {
                widths.insert(width)
            }
        }
        return widths
    }

    /// The file is a well-formed icns (`icns` magic, declared length, chunk lengths add up) holding
    /// exactly the chunks of `expectedSizes`, and ImageIO can read the sizes it supports.
    private func expectValidIcns(_ data: Data, sizes expectedSizes: [Int]) {
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "icns")
        guard let chunks = ShortcutIconBuilder.parseChunks(data) else {
            Issue.record("not a well-formed icns")
            return
        }
        var expectedTypes = expectedSizes.compactMap { ShortcutIconBuilder.chunkTypes[$0] }
        // The two smallest sizes are classic RGB chunks with a separate 8-bit mask chunk each.
        if expectedSizes.contains(16) {
            expectedTypes.append("s8mk")
        }
        if expectedSizes.contains(32) {
            expectedTypes.append("l8mk")
        }
        #expect(chunks.map(\.type).sorted() == expectedTypes.sorted())
        let readableSizes = Set(expectedSizes).intersection([16, 32, 128, 256, 512])
        #expect(Self.icnsPixelWidths(data).isSuperset(of: readableSizes))
        for chunk in chunks where chunk.type == "icp6" || chunk.type == "ic10" {
            #expect(chunk.payload.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        }
    }

    @Test func iconIsAnIcnsWithTheStandardSizesTheSourceAllows() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        let game = Self.makeGame("icon-game", title: "Icon Game")
        try environment.shortcuts.install(for: game, locations: [.desktop], iconPath: environment.iconPath)

        let icnsData = try Data(
            contentsOf: URL(fileURLWithPath: environment.desktopDirectory + "/Icon Game.app/" + ShortcutBundle
                .iconRelativePath)
        )
        expectValidIcns(icnsData, sizes: [16, 32, 64, 128, 256, 512, 1024])

        let smallIconPath = environment.paths.home + "/small.png"
        try Self.writePNG(side: 48, to: smallIconPath)
        let smallData = try #require(
            ShortcutIconBuilder.icnsData(iconPath: smallIconPath, fallbackIconPath: environment.fallbackIconPath)
        )
        expectValidIcns(smallData, sizes: [16, 32])
    }

    @Test func nonSquareIconsAreFittedOntoASquare() throws {
        let context = try #require(CGContext(
            data: nil, width: 300, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 100))
        let image = try #require(context.makeImage())
        let icnsData = try #require(ShortcutIconBuilder.icnsData(from: image))
        expectValidIcns(icnsData, sizes: [16, 32, 64, 128, 256])
    }

    @Test func missingOrCorruptIconFallsBackToTheFaugusIcon() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        let corruptIconPath = environment.paths.home + "/corrupt.png"
        try Data("not a png".utf8).write(to: URL(fileURLWithPath: corruptIconPath))

        for (index, iconPath) in [nil, environment.paths.home + "/missing.png", corruptIconPath].enumerated() {
            let game = Self.makeGame("fallback-\(index)", title: "Fallback \(index)")
            try environment.shortcuts.install(for: game, locations: [.desktop], iconPath: iconPath)
            let icnsData = try Data(
                contentsOf: URL(
                    fileURLWithPath: environment.desktopDirectory + "/Fallback \(index).app/" + ShortcutBundle
                        .iconRelativePath
                )
            )
            // The fallback is 256 px, so it tops out at 256.
            expectValidIcns(icnsData, sizes: [16, 32, 64, 128, 256])
        }
    }

    @Test func unreadableIconAndFallbackLeavesAnExistingBundleUntouched() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        let game = Self.makeGame("keep", title: "Keep")
        try environment.shortcuts.install(for: game, locations: [.desktop], iconPath: environment.iconPath)
        let scriptPath = environment.desktopDirectory + "/Keep.app/" + ShortcutBundle.launchScriptRelativePath
        let scriptBefore = try String(contentsOfFile: scriptPath, encoding: .utf8)

        let brokenShortcuts = GameShortcuts(
            paths: environment.paths, executablePath: "/somewhere/else",
            fallbackIconPath: environment.paths.home + "/nope.png"
        )
        #expect(throws: ShortcutError.iconUnavailable) {
            try brokenShortcuts.install(for: game, locations: [.desktop], iconPath: nil)
        }
        #expect(try String(contentsOfFile: scriptPath, encoding: .utf8) == scriptBefore)
        #expect(Self.bundleNames(in: environment.desktopDirectory) == ["Keep.app"])
    }
}

extension ShortcutsTests {
    // MARK: Atomic replace

    @Test func replacingABundleSwapsItWholeAndLeavesNoStagingFolder() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        let marker = ShortcutMarker(gameID: "swap", kind: .game)
        let bundlePath = environment.desktopDirectory + "/Swap.app"

        try ShortcutBundle.write(
            at: bundlePath, title: "Swap", marker: marker,
            launch: ShortcutLaunch(executablePath: "/first", arguments: ["one"]),
            iconPath: nil, fallbackIconPath: environment.fallbackIconPath
        )
        try "stale".write(toFile: bundlePath + "/Contents/Resources/stale.txt", atomically: true, encoding: .utf8)
        try ShortcutBundle.write(
            at: bundlePath, title: "Swap Two", marker: marker,
            launch: ShortcutLaunch(executablePath: "/second", arguments: ["two"]),
            iconPath: nil, fallbackIconPath: environment.fallbackIconPath
        )

        let script = try String(
            contentsOfFile: bundlePath + "/" + ShortcutBundle.launchScriptRelativePath,
            encoding: .utf8
        )
        #expect(script.contains("exec /second two"))
        #expect(!script.contains("/first"))
        #expect(!FileManager.default.fileExists(atPath: bundlePath + "/Contents/Resources/stale.txt"))
        #expect(Self.bundleNames(in: environment.desktopDirectory) == ["Swap.app"])
    }

    @Test func aFailedWriteLeavesNoPartialBundleBehind() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        #expect(throws: ShortcutError.iconUnavailable) {
            try ShortcutBundle.write(
                at: environment.desktopDirectory + "/Broken.app", title: "Broken",
                marker: ShortcutMarker(gameID: "broken", kind: .game),
                launch: ShortcutLaunch(executablePath: "/x", arguments: []),
                iconPath: nil, fallbackIconPath: environment.paths.home + "/missing.png"
            )
        }
        #expect(Self.bundleNames(in: environment.desktopDirectory).isEmpty)
    }
}

extension ShortcutsTests {
    // MARK: Marker-gated deletion

    @Test func aForeignBundleIsNeverDeletedOrOverwritten() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        let foreignPath = environment.desktopDirectory + "/Foreign.app"
        try Self.makeForeignBundle(at: foreignPath)
        let game = Self.makeGame("foreign", title: "Foreign")

        // Writing straight onto it is refused.
        #expect(throws: ShortcutError.foreignBundleInTheWay(foreignPath)) {
            try ShortcutBundle.write(
                at: foreignPath, title: "Foreign", marker: ShortcutMarker(gameID: "foreign", kind: .game),
                launch: ShortcutLaunch(executablePath: "/x", arguments: []),
                iconPath: nil, fallbackIconPath: environment.fallbackIconPath
            )
        }
        // The service picks another name instead of clobbering it.
        let installed = try environment.shortcuts.install(for: game, locations: [.desktop])
        #expect(installed[.desktop] == environment.desktopDirectory + "/Foreign 2.app")
        // Removing the game's shortcut leaves the foreign bundle alone.
        #expect(try environment.shortcuts.remove(gameID: "foreign") == [.desktop])
        #expect(Self.bundleNames(in: environment.desktopDirectory) == ["Foreign.app"])
        #expect(try ShortcutBundle.remove(bundleAt: foreignPath) == false)
        #expect(try String(contentsOfFile: foreignPath + "/Contents/Info.plist", encoding: .utf8) == "foreign")
    }

    @Test func aBundleWithAnotherGameIDMarkerIsNotRemovedByThisGame() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        let other = Self.makeGame("other", title: "Same Title")
        try environment.shortcuts.install(for: other, locations: [.desktop])

        let game = Self.makeGame("mine", title: "Same Title")
        #expect(try environment.shortcuts.remove(gameID: "mine").isEmpty)
        #expect(environment.shortcuts.existingLocations(gameID: "other") == [.desktop])
        #expect(Self.bundleNames(in: environment.desktopDirectory) == ["Same Title.app"])

        let installed = try environment.shortcuts.install(for: game, locations: [.desktop])
        #expect(installed[.desktop] == environment.desktopDirectory + "/Same Title 2.app")
        #expect(environment.shortcuts.existingLocations(gameID: "other") == [.desktop])
    }

    @Test func symlinkedBundlesAreNeitherFollowedNorDeleted() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        let game = Self.makeGame("linked", title: "Linked")
        let realBundles = environment.paths.home + "/elsewhere"
        try FileManager.default.createDirectory(atPath: realBundles, withIntermediateDirectories: true)
        let realBundlePath = realBundles + "/Real.app"
        try ShortcutBundle.write(
            at: realBundlePath, title: "Linked", marker: ShortcutMarker(gameID: "linked", kind: .game),
            launch: ShortcutLaunch(executablePath: "/x", arguments: []),
            iconPath: nil, fallbackIconPath: environment.fallbackIconPath
        )
        try FileManager.default.createDirectory(atPath: environment.desktopDirectory, withIntermediateDirectories: true)
        let linkPath = environment.desktopDirectory + "/Linked.app"
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: realBundlePath)

        #expect(ShortcutBundle.marker(atBundlePath: linkPath) == nil)
        #expect(try ShortcutBundle.remove(bundleAt: linkPath) == false)
        #expect(environment.shortcuts.existingLocations(gameID: "linked").isEmpty)
        #expect(throws: ShortcutError.foreignBundleInTheWay(linkPath)) {
            try ShortcutBundle.write(
                at: linkPath, title: "Linked", marker: ShortcutMarker(gameID: "linked", kind: .game),
                launch: ShortcutLaunch(executablePath: "/y", arguments: []),
                iconPath: nil, fallbackIconPath: environment.fallbackIconPath
            )
        }
        // The service skips the symlink and the target keeps its original content.
        let installed = try environment.shortcuts.install(for: game, locations: [.desktop])
        #expect(installed[.desktop] == environment.desktopDirectory + "/Linked 2.app")
        let targetScript = try String(
            contentsOfFile: realBundlePath + "/" + ShortcutBundle.launchScriptRelativePath, encoding: .utf8
        )
        #expect(targetScript.contains("exec /x"))
        #expect(FileManager.default.fileExists(atPath: linkPath))
    }

    @Test func removeDeletesEveryLocationFoundByMarkerAndReportsThem() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        let game = Self.makeGame("both", title: "Both")
        try environment.shortcuts.install(for: game, locations: [.applicationsMenu, .desktop])
        #expect(environment.shortcuts.existingLocations(gameID: "both") == [.applicationsMenu, .desktop])

        #expect(try environment.shortcuts.remove(gameID: "both", locations: [.desktop]) == [.desktop])
        #expect(environment.shortcuts.existingLocations(gameID: "both") == [.applicationsMenu])
        #expect(try environment.shortcuts.remove(gameID: "both") == [.applicationsMenu])
        #expect(environment.shortcuts.existingLocations(gameID: "both").isEmpty)
        #expect(Self.bundleNames(in: environment.applicationsDirectory).isEmpty)
    }
}

extension ShortcutsTests {
    // MARK: Rename, update, scan by marker

    @Test func renamingAGameMovesItsShortcutAndKeepsTheLocationSet() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        var game = Self.makeGame("renamed", title: "Old Name")
        try environment.shortcuts.install(for: game, locations: [.desktop])
        #expect(environment.shortcuts.existingLocations(gameID: "renamed") == [.desktop])

        game.title = "New Name"
        #expect(try environment.shortcuts.update(for: game) == [.desktop])

        #expect(Self.bundleNames(in: environment.desktopDirectory) == ["New Name.app"])
        #expect(Self.bundleNames(in: environment.applicationsDirectory).isEmpty)
        #expect(environment.shortcuts.existingLocations(gameID: "renamed") == [.desktop])
        let plistData = try Data(
            contentsOf: URL(fileURLWithPath: environment.desktopDirectory + "/New Name.app/Contents/Info.plist")
        )
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        )
        #expect(plist["CFBundleDisplayName"] as? String == "New Name")
    }

    @Test func updatingAGameWithoutShortcutsCreatesNone() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        let game = Self.makeGame("plain", title: "Plain")
        #expect(try environment.shortcuts.update(for: game).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: environment.desktopDirectory))
        #expect(!FileManager.default.fileExists(atPath: environment.applicationsDirectory))
    }

    @Test func existingLocationsScansByMarkerNotByFileName() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        let game = Self.makeGame("scan", title: "Scan")
        try environment.shortcuts.install(for: game, locations: [.applicationsMenu])
        try FileManager.default.moveItem(
            atPath: environment.applicationsDirectory + "/Scan.app",
            toPath: environment.applicationsDirectory + "/Totally Different.app"
        )
        #expect(environment.shortcuts.existingLocations(gameID: "scan") == [.applicationsMenu])

        // Updating re-uses that bundle's identity: the stray name is replaced by the right one.
        try environment.shortcuts.update(for: game)
        #expect(Self.bundleNames(in: environment.applicationsDirectory) == ["Scan.app"])
    }

    @Test func installingAgainReplacesTheSameBundleInPlace() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        var game = Self.makeGame("again", title: "Again", directory: environment.paths.home + "/first")
        try environment.shortcuts.install(for: game, locations: [.desktop])
        game.path = environment.paths.home + "/second/game.exe"
        try environment.shortcuts.install(for: game, locations: [.desktop])

        #expect(Self.bundleNames(in: environment.desktopDirectory) == ["Again.app"])
        let script = try String(
            contentsOfFile: environment.desktopDirectory + "/Again.app/" + ShortcutBundle.launchScriptRelativePath,
            encoding: .utf8
        )
        #expect(script.contains(environment.paths.home + "/second"))
        #expect(!script.contains(environment.paths.home + "/first"))
    }
}

extension ShortcutsTests {
    // MARK: File names

    @Test func fileNamesAreSanitisedForTheFilesystem() {
        #expect(ShortcutLibrary.sanitizedFileName("A/B:C", fallback: "id") == "ABC")
        #expect(ShortcutLibrary.sanitizedFileName("  ..hidden  ", fallback: "id") == "hidden")
        #expect(ShortcutLibrary.sanitizedFileName("tab\there\u{0}x", fallback: "id") == "tabherex")
        #expect(ShortcutLibrary.sanitizedFileName("  Spaces  inside  ", fallback: "id") == "Spaces  inside")
        #expect(ShortcutLibrary.sanitizedFileName("...", fallback: "game-id") == "game-id")
        #expect(ShortcutLibrary.sanitizedFileName("/:", fallback: "/fallback:") == "fallback")
        #expect(ShortcutLibrary.sanitizedFileName("", fallback: "") == "Shortcut")
        #expect(ShortcutLibrary.sanitizedFileName("日本語のゲーム", fallback: "id") == "日本語のゲーム")
        let long = String(repeating: "あ", count: 200)
        #expect(ShortcutLibrary.sanitizedFileName(long, fallback: "id").utf8.count <= ShortcutLibrary
            .maximumFileNameBytes)
    }

    @Test func aTitleThatSanitisesToNothingUsesTheGameID() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        let game = Self.makeGame("fallback-id", title: "../..")
        let installed = try environment.shortcuts.install(for: game, locations: [.desktop])
        #expect(installed[.desktop] == environment.desktopDirectory + "/fallback-id.app")
    }

    @Test func collidingTitlesAreNumberedWithoutClobbering() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        let first = Self.makeGame("one", title: "Same")
        let second = Self.makeGame("two", title: "Same")
        let third = Self.makeGame("three", title: "Same")
        try environment.shortcuts.install(for: first, locations: [.desktop])
        try environment.shortcuts.install(for: second, locations: [.desktop])
        try environment.shortcuts.install(for: third, locations: [.desktop])
        #expect(Self.bundleNames(in: environment.desktopDirectory) == ["Same 2.app", "Same 3.app", "Same.app"])
        #expect(ShortcutBundle.marker(atBundlePath: environment.desktopDirectory + "/Same.app")?.gameID == "one")
        #expect(ShortcutBundle.marker(atBundlePath: environment.desktopDirectory + "/Same 2.app")?.gameID == "two")
        #expect(ShortcutBundle.marker(atBundlePath: environment.desktopDirectory + "/Same 3.app")?.gameID == "three")

        // Re-installing or updating a numbered shortcut keeps its slot.
        try environment.shortcuts.update(for: second)
        #expect(Self.bundleNames(in: environment.desktopDirectory) == ["Same 2.app", "Same 3.app", "Same.app"])
        #expect(ShortcutBundle.marker(atBundlePath: environment.desktopDirectory + "/Same 2.app")?.gameID == "two")

        // A freed name is reused by the next newcomer.
        try environment.shortcuts.remove(gameID: "one")
        let fourth = Self.makeGame("four", title: "Same")
        let installed = try environment.shortcuts.install(for: fourth, locations: [.desktop])
        #expect(installed[.desktop] == environment.desktopDirectory + "/Same.app")
    }

    @Test func aGameWithoutAnIDIsRefused() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        let game = Self.makeGame("", title: "No ID")
        #expect(throws: ShortcutError.missingIdentifier) {
            try environment.shortcuts.install(for: game, locations: [.desktop])
        }
    }
}

extension ShortcutsTests {
    // MARK: File shortcuts

    private static func makeFileShortcut(
        _ environment: Environment,
        title: String = "My Installer Tool"
    ) -> FileShortcut {
        var shortcut = FileShortcut(
            title: title,
            executablePath: environment.paths.home + "/downloads/Setup Tool.exe",
            prefixPath: environment.paths.home + "/Faugus/default",
            runnerName: "Wine-Staging-11.21"
        )
        shortcut.iconPath = environment.iconPath
        return shortcut
    }

    @Test func fileShortcutArgumentsUseTheExistingRunGrammar() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        var shortcut = Self.makeFileShortcut(environment)
        shortcut.preLaunch = "/bin/echo before 'x'"
        shortcut.postLaunch = "after $HOME"

        let arguments = shortcut.faugusArguments(paths: environment.paths)
        #expect(arguments.first == "--run")
        #expect(
            LaunchMode.parse(arguments) == .runFile(
                path: environment.paths.home + "/downloads/Setup Tool.exe",
                target: .prefix(
                    path: environment.paths.home + "/Faugus/default", runner: "Wine-Staging-11.21",
                    logID: "my-installer-tool"
                ),
                logs: false, preLaunch: "/bin/echo before 'x'", postLaunch: "after $HOME"
            )
        )

        shortcut.preLaunch = ""
        shortcut.postLaunch = ""
        #expect(!shortcut.faugusArguments(paths: environment.paths).contains("--pre-launch"))
        #expect(!shortcut.faugusArguments(paths: environment.paths).contains("--post-launch"))
    }

    @Test func fileShortcutInstallsIntoBothLocationsKeyedByTheFormattedTitle() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        let fileDirectory = environment.paths.home + "/downloads"
        try FileManager.default.createDirectory(atPath: fileDirectory, withIntermediateDirectories: true)
        var shortcut = Self.makeFileShortcut(environment)
        shortcut.sdlEnabled = true
        shortcut.noSleepEnabled = true
        shortcut.launchArguments = "CUSTOM_VARIABLE='a b' mangohud"
        shortcut.gameArguments = "-fullscreen"

        let installed = try shortcut.install(in: environment.library)
        #expect(installed == [
            .applicationsMenu: environment.applicationsDirectory + "/My Installer Tool.app",
            .desktop: environment.desktopDirectory + "/My Installer Tool.app",
        ])
        for bundlePath in installed.values {
            #expect(ShortcutBundle.marker(atBundlePath: bundlePath) == ShortcutMarker(
                gameID: "my-installer-tool",
                kind: .file
            ))
        }
        #expect(shortcut.existingLocations(in: environment.library) == [.applicationsMenu, .desktop])
        #expect(environment.shortcuts.existingLocations(gameID: "my-installer-tool").isEmpty)

        let dump = try Self.runLaunchScript(
            of: environment.desktopDirectory + "/My Installer Tool.app", dumpPath: environment.dumpPath
        )
        let expectedArguments = shortcut.faugusArguments(paths: environment.paths)
        #expect(dump == [Self.realPath(fileDirectory)] + expectedArguments + ["1", "1", "a b"])

        // Removing by title key deletes both bundles.
        #expect(try shortcut.remove(from: environment.library) == [.applicationsMenu, .desktop])
        #expect(Self.bundleNames(in: environment.desktopDirectory).isEmpty)
        #expect(Self.bundleNames(in: environment.applicationsDirectory).isEmpty)
    }

    @Test func fileShortcutAndGameShortcutWithTheSameIDDoNotClobberEachOther() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        let game = Self.makeGame("my-installer-tool", title: "My Installer Tool")
        try environment.shortcuts.install(for: game, locations: [.desktop])
        let shortcut = Self.makeFileShortcut(environment)
        let installed = try shortcut.install(in: environment.library)

        #expect(installed[.desktop] == environment.desktopDirectory + "/My Installer Tool 2.app")
        #expect(environment.shortcuts.existingLocations(gameID: "my-installer-tool") == [.desktop])
        #expect(shortcut.existingLocations(in: environment.library) == [.applicationsMenu, .desktop])
        #expect(try environment.shortcuts.remove(gameID: "my-installer-tool") == [.desktop])
        #expect(Self.bundleNames(in: environment.desktopDirectory) == ["My Installer Tool 2.app"])
    }

    @Test func fileShortcutWithoutWordCharactersInItsTitleIsRefused() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        let shortcut = Self.makeFileShortcut(environment, title: "!!!")
        #expect(throws: ShortcutError.missingIdentifier) {
            try shortcut.install(in: environment.library)
        }
        #expect(!FileManager.default.fileExists(atPath: environment.desktopDirectory))
    }

    @Test func fileShortcutWithUnbalancedLaunchArgumentQuotesIsRefused() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        var shortcut = Self.makeFileShortcut(environment)
        shortcut.launchArguments = "FOO='unterminated"
        #expect(throws: ShortcutError.self) {
            try shortcut.install(in: environment.library)
        }
        #expect(Self.bundleNames(in: environment.desktopDirectory).isEmpty)
    }

    @Test func nothingIsWrittenOutsideTheInjectedHome() throws {
        let environment = try Self.makeEnvironment()
        defer { TestSupport.cleanup(environment.paths) }
        let game = Self.makeGame("contained", title: "Contained")
        try environment.shortcuts.install(for: game, locations: [.applicationsMenu, .desktop])
        #expect(environment.applicationsDirectory.hasPrefix(environment.paths.home + "/"))
        #expect(environment.desktopDirectory.hasPrefix(environment.paths.home + "/"))
        #expect(environment.library.directory(for: .desktop) == environment.paths.home + "/Desktop")
        #expect(environment.library.directory(for: .applicationsMenu) == environment.paths
            .home + "/Applications/Faugus")
    }
}
