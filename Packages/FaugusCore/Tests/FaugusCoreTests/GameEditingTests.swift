import Foundation
import Testing

@testable import FaugusCore

private func tempPaths() -> FaugusPaths {
    let dir = NSTemporaryDirectory() + "faugus-edit-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return FaugusPaths(home: dir)
}

@Suite("Game editing rules")
struct GameEditingTests {
    @Test func validationFlagsEmptyFields() {
        #expect(GameEditing.invalidFields(title: "", path: "", prefix: "") == [.title, .path, .prefix])
        #expect(GameEditing.invalidFields(title: "Hello", path: "/a.exe", prefix: "/p").isEmpty)
        // A title that formats to nothing is as bad as an empty one.
        #expect(GameEditing.invalidFields(title: "!!!", path: "/a.exe", prefix: "/p") == [.title])
    }

    @Test func titleExistsIsCaseInsensitive() {
        let games = [Game(gameID: "hello", title: "Hello World")]
        #expect(GameEditing.titleExists("hello world", in: games))
        #expect(!GameEditing.titleExists("Hello", in: games))
        #expect(!GameEditing.titleExists("HELLO WORLD", in: games, ignoring: "hello"))
    }

    @Test func normpath() {
        #expect(GameEditing.normalizedPath("/a/b/../c//d/.") == "/a/c/d")
        #expect(GameEditing.normalizedPath("/a/b/") == "/a/b")
        #expect(GameEditing.normalizedPath("a/../..") == "..")
        #expect(GameEditing.normalizedPath("") == ".")
    }

    @Test func batMatchesUpstreamLayout() {
        let first = GameEditing.addAppBatContents(
            exe: "/g/game.exe", addApp: "/t/tool.exe", delay: "5", first: true, gameArguments: "-w")
        #expect(first == "@echo off\nstart \"\" \"z:/t/tool.exe\"\nping -n 5 127.0.0.1 >nul\nstart \"\" \"z:/g/game.exe\" -w\n")
        let second = GameEditing.addAppBatContents(
            exe: "/g/game.exe", addApp: "/t/tool.exe", delay: "", first: false, gameArguments: "")
        #expect(second == "@echo off\nstart \"\" \"z:/g/game.exe\"\nstart \"\" \"z:/t/tool.exe\"\n")
    }

    @Test func duplicateCopiesFilesAndGetsNewID() throws {
        let paths = tempPaths()
        let fm = FileManager.default
        for d in [paths.iconsDir, paths.coversDir, paths.bannersDir] { try fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
        try Data([1]).write(to: URL(fileURLWithPath: "\(paths.iconsDir)/hello.png"))
        try Data([2]).write(to: URL(fileURLWithPath: "\(paths.coversDir)/hello.png"))
        try Data([3]).write(to: URL(fileURLWithPath: "\(paths.bannersDir)/hello.png"))
        var g = Game(gameID: "hello", title: "Hello")
        g.icon = "\(paths.iconsDir)/hello.png"
        g.cover = "\(paths.coversDir)/hello.png"
        g.playtime = 77
        let dup = try GameEditing.duplicate(g, newTitle: "  Hello 2 ", existing: [g], paths: paths)
        #expect(dup.gameID == "hello-2")
        #expect(dup.title == "Hello 2")
        #expect(dup.playtime == 77)
        #expect(fm.contents(atPath: "\(paths.iconsDir)/hello-2.png") == Data([1]))
        #expect(fm.contents(atPath: "\(paths.coversDir)/hello-2.png") == Data([2]))
        #expect(fm.contents(atPath: "\(paths.bannersDir)/hello-2.png") == Data([3]))
        #expect(dup.cover == "\(paths.coversDir)/hello-2.png")
        // The original keeps its files.
        #expect(fm.fileExists(atPath: "\(paths.iconsDir)/hello.png"))
    }

    @Test func duplicateRejectsBadTitles() throws {
        let paths = tempPaths()
        let g = Game(gameID: "hello", title: "Hello")
        #expect(throws: GameEditing.DuplicateError.invalidTitle) {
            try GameEditing.duplicate(g, newTitle: "   ", existing: [g], paths: paths)
        }
        #expect(throws: GameEditing.DuplicateError.exists) {
            try GameEditing.duplicate(g, newTitle: "HELLO", existing: [g], paths: paths)
        }
    }

    @Test func deleteRemovesOnlyOwnedFiles() throws {
        let paths = tempPaths()
        let fm = FileManager.default
        let gameDir = paths.dataDir + "/g"
        for d in [paths.iconsDir, paths.coversDir, paths.bannersDir, gameDir] { try fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
        for d in [paths.iconsDir, paths.coversDir, paths.bannersDir] { try Data([1]).write(to: URL(fileURLWithPath: "\(d)/hello.png")) }
        try Data([1]).write(to: URL(fileURLWithPath: "\(gameDir)/faugus-hello.bat"))
        try Data([1]).write(to: URL(fileURLWithPath: "\(gameDir)/game.exe"))
        var g = Game(gameID: "hello", title: "Hello")
        g.addAppBat = "\(gameDir)/faugus-hello.bat"
        g.path = "\(gameDir)/game.exe"
        GameEditing.removeOwnedFiles(of: g, paths: paths)
        for f in GameEditing.artworkFiles(for: "hello", paths: paths) { #expect(!fm.fileExists(atPath: f)) }
        #expect(!fm.fileExists(atPath: g.addAppBat))
        #expect(fm.fileExists(atPath: g.path))

        // A bat that is not Faugus's own is left alone.
        try Data([1]).write(to: URL(fileURLWithPath: "\(gameDir)/mine.bat"))
        g.addAppBat = "\(gameDir)/mine.bat"
        GameEditing.removeOwnedFiles(of: g, paths: paths)
        #expect(fm.fileExists(atPath: "\(gameDir)/mine.bat"))
    }

    @Test func prefixSharingAndRemovalOffer() {
        let paths = tempPaths()
        var a = Game(gameID: "a", title: "A"); a.prefix = "/p/shared"
        var b = Game(gameID: "b", title: "B"); b.prefix = "/p/shared"
        var c = Game(gameID: "c", title: "C"); c.prefix = "/p/own"
        #expect(GameEditing.otherGamesUsingPrefix(of: a, in: [a, b, c], paths: paths) == 1)
        #expect(GameEditing.otherGamesUsingPrefix(of: c, in: [a, b, c], paths: paths) == 0)
        #expect(GameEditing.offersPrefixRemoval(for: c, paths: paths))
        c.prefix = "/p/default"
        #expect(!GameEditing.offersPrefixRemoval(for: c, paths: paths))
        c.prefix = "/p/own"; c.runner = "Steam"
        #expect(!GameEditing.offersPrefixRemoval(for: c, paths: paths))
    }

    @Test func applyWritesDraftAndKeepsUnknownFields() throws {
        let paths = tempPaths()
        var original = Game(gameID: "hello", title: "Hello")
        original.playtime = 90
        original.category = .array([.string("RPG")])
        var d = GameEditing.Draft()
        d.title = "Hello Edited"
        d.path = "/g/game.exe"
        d.prefix = "/p/x/../hello/"
        d.customRunner = true
        d.runner = "Wine-Staging-11.21"
        d.graphics = .dxvk
        d.launchArguments = ["DXVK_HUD=fps", "", "mangohud"]
        d.gameArguments = "-w"
        d.preLaunch = "  /bin/pre.sh \n"
        d.sdl = true
        d.addAppEnabled = true
        d.addAppPath = "/t/tool.exe"
        d.addAppDelay = 3
        d.addAppFirst = true
        let g = GameEditing.apply(d, to: original, paths: paths)
        #expect(g.gameID == "hello")
        #expect(g.title == "Hello Edited")
        #expect(g.prefix == "/p/hello")
        #expect(g.runner == "Wine-Staging-11.21")
        #expect(g.graphics == .dxvk)
        #expect(g.launchArguments == "DXVK_HUD=fps\nmangohud")
        #expect(g.preLaunch == "/bin/pre.sh")
        #expect(g.sdlEnabled && g.addAppEnabled && g.addAppFirst)
        #expect(g.addAppDelay == "3")
        #expect(g.addAppBat == "/g/faugus-hello.bat")
        // Not edited here: kept.
        #expect(g.playtime == 90)
        #expect(g.category == .array([.string("RPG")]))

        d.customRunner = false
        d.graphics = .default
        let back = GameEditing.apply(d, to: g, paths: paths)
        #expect(back.runner == "Default")
        #expect(back.graphics == nil)
    }

    @Test func formatFillsPercentD() {
        #expect(Translator.fill("used by %d other games", args: ["3"]) == "used by 3 other games")
    }

    @Test func presetsAndLaunchLines() throws {
        let paths = tempPaths()
        let store = PresetsStore(paths: paths)
        #expect(store.load().isEmpty)
        try store.save(["A=1", "  ", "B=2"])
        #expect(store.load() == ["A=1", "B=2"])
        #expect(LaunchArgumentLines.split("A=1\n\n  \nB=2\n") == ["A=1", "B=2"])
        #expect(LaunchArgumentLines.join(["A=1", "", "B=2"]) == "A=1\nB=2")
    }
}

@Suite("Steam game type editing")
struct SteamEditingTests {
    @Test func steamDraftClearsWineOptions() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        var d = GameEditing.Draft()
        d.title = "Celeste"
        d.path = "504230"
        d.prefix = paths.home + "/Faugus/celeste"
        d.steamUser = "1034930219"
        d.noSleep = true
        d.sdl = true
        d.discordRPC = true
        d.addAppEnabled = true
        d.addAppPath = "/x.exe"
        d.customRunner = true
        d.runner = "Wine-Staging-11.21"
        d.graphics = .dxvk
        var base = Game(gameID: "celeste", title: "Celeste")
        base.mangohud = true
        let g = GameEditing.apply(d, to: base, paths: paths)
        #expect(g.runner == "Steam")
        #expect(g.path == "504230")
        #expect(g.steamUser == "1034930219")
        #expect(g.graphics == nil)
        #expect(!g.sdlEnabled && !g.noSleep && !g.discordRPC && !g.addAppEnabled && !g.mangohud)
        #expect(g.addApp.isEmpty && g.addAppBat.isEmpty)
    }

    @Test func windowsDraftLeavesSteamUserEmpty() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        var d = GameEditing.Draft()
        d.title = "A"
        d.path = "/a.exe"
        d.prefix = "/p"
        var base = Game(gameID: "a", title: "A")
        base.steamUser = "1"
        let g = GameEditing.apply(d, to: base, paths: paths)
        #expect(g.steamUser.isEmpty)
        #expect(g.runner == "Default")
    }

    @Test func steamSelectionIsRequired() {
        #expect(GameEditing.steamSelectionMissing(appID: ""))
        #expect(GameEditing.steamSelectionMissing(appID: "  "))
        #expect(!GameEditing.steamSelectionMissing(appID: "504230"))
    }
}
