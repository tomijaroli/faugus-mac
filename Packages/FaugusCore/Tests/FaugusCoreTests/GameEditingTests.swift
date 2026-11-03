@testable import FaugusCore
import Foundation
import Testing

private func makeTemporaryPaths() -> FaugusPaths {
    let directory = NSTemporaryDirectory() + "faugus-edit-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    return FaugusPaths(home: directory)
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

    @Test func normalizedPathMatchesPythonNormpath() {
        #expect(GameEditing.normalizedPath("/a/b/../c//d/.") == "/a/c/d")
        #expect(GameEditing.normalizedPath("/a/b/") == "/a/b")
        #expect(GameEditing.normalizedPath("a/../..") == "..")
        #expect(GameEditing.normalizedPath("") == ".")
    }

    @Test func batMatchesUpstreamLayout() {
        let first = GameEditing.addAppBatContents(
            executable: "/g/game.exe", addApp: "/t/tool.exe", delay: "5", first: true, gameArguments: "-w"
        )
        #expect(first ==
            "@echo off\nstart \"\" \"z:/t/tool.exe\"\nping -n 5 127.0.0.1 >nul\nstart \"\" \"z:/g/game.exe\" -w\n")
        let second = GameEditing.addAppBatContents(
            executable: "/g/game.exe", addApp: "/t/tool.exe", delay: "", first: false, gameArguments: ""
        )
        #expect(second == "@echo off\nstart \"\" \"z:/g/game.exe\"\nstart \"\" \"z:/t/tool.exe\"\n")
    }

    @Test func duplicateCopiesFilesAndGetsNewID() throws {
        let paths = makeTemporaryPaths()
        let fileManager = FileManager.default
        for directory in [paths.iconsDirectory, paths.coversDirectory, paths.bannersDirectory] {
            try fileManager.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true
            )
        }
        try Data([1]).write(to: URL(fileURLWithPath: "\(paths.iconsDirectory)/hello.png"))
        try Data([2]).write(to: URL(fileURLWithPath: "\(paths.coversDirectory)/hello.png"))
        try Data([3]).write(to: URL(fileURLWithPath: "\(paths.bannersDirectory)/hello.png"))
        var game = Game(gameID: "hello", title: "Hello")
        game.icon = "\(paths.iconsDirectory)/hello.png"
        game.cover = "\(paths.coversDirectory)/hello.png"
        game.playtime = 77
        let duplicatedGame = try GameEditing.duplicate(game, newTitle: "  Hello 2 ", existing: [game], paths: paths)
        #expect(duplicatedGame.gameID == "hello-2")
        #expect(duplicatedGame.title == "Hello 2")
        #expect(duplicatedGame.playtime == 77)
        #expect(fileManager.contents(atPath: "\(paths.iconsDirectory)/hello-2.png") == Data([1]))
        #expect(fileManager.contents(atPath: "\(paths.coversDirectory)/hello-2.png") == Data([2]))
        #expect(fileManager.contents(atPath: "\(paths.bannersDirectory)/hello-2.png") == Data([3]))
        #expect(duplicatedGame.cover == "\(paths.coversDirectory)/hello-2.png")
        // The original keeps its files.
        #expect(fileManager.fileExists(atPath: "\(paths.iconsDirectory)/hello.png"))
    }

    @Test func duplicateRejectsBadTitles() throws {
        let paths = makeTemporaryPaths()
        let game = Game(gameID: "hello", title: "Hello")
        #expect(throws: GameEditing.DuplicateError.invalidTitle) {
            try GameEditing.duplicate(game, newTitle: "   ", existing: [game], paths: paths)
        }
        #expect(throws: GameEditing.DuplicateError.exists) {
            try GameEditing.duplicate(game, newTitle: "HELLO", existing: [game], paths: paths)
        }
    }

    @Test func deleteRemovesOnlyOwnedFiles() throws {
        let paths = makeTemporaryPaths()
        let fileManager = FileManager.default
        let gameDirectory = paths.dataDirectory + "/g"
        for directory in [paths.iconsDirectory, paths.coversDirectory, paths.bannersDirectory, gameDirectory] {
            try fileManager.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true
            )
        }
        for directory in [paths.iconsDirectory, paths.coversDirectory, paths.bannersDirectory] {
            try Data([1]).write(to: URL(fileURLWithPath: "\(directory)/hello.png"))
        }
        try Data([1]).write(to: URL(fileURLWithPath: "\(gameDirectory)/faugus-hello.bat"))
        try Data([1]).write(to: URL(fileURLWithPath: "\(gameDirectory)/game.exe"))
        var game = Game(gameID: "hello", title: "Hello")
        game.addAppBat = "\(gameDirectory)/faugus-hello.bat"
        game.path = "\(gameDirectory)/game.exe"
        GameEditing.removeOwnedFiles(of: game, paths: paths)
        for file in GameEditing.artworkFiles(for: "hello", paths: paths) {
            #expect(!fileManager.fileExists(atPath: file))
        }
        #expect(!fileManager.fileExists(atPath: game.addAppBat))
        #expect(fileManager.fileExists(atPath: game.path))

        // A bat that is not Faugus's own is left alone.
        try Data([1]).write(to: URL(fileURLWithPath: "\(gameDirectory)/mine.bat"))
        game.addAppBat = "\(gameDirectory)/mine.bat"
        GameEditing.removeOwnedFiles(of: game, paths: paths)
        #expect(fileManager.fileExists(atPath: "\(gameDirectory)/mine.bat"))
    }

    @Test func prefixSharingAndRemovalOffer() {
        let paths = makeTemporaryPaths()
        var sharedGame = Game(gameID: "a", title: "A")
        sharedGame.prefix = "/p/shared"
        var otherSharedGame = Game(gameID: "b", title: "B")
        otherSharedGame.prefix = "/p/shared"
        var ownGame = Game(gameID: "c", title: "C")
        ownGame.prefix = "/p/own"
        #expect(GameEditing.otherGamesUsingPrefix(
            of: sharedGame,
            in: [sharedGame, otherSharedGame, ownGame],
            paths: paths
        ) == 1)
        #expect(GameEditing.otherGamesUsingPrefix(
            of: ownGame,
            in: [sharedGame, otherSharedGame, ownGame],
            paths: paths
        ) == 0)
        #expect(GameEditing.offersPrefixRemoval(for: ownGame, paths: paths))
        ownGame.prefix = "/p/default"
        #expect(!GameEditing.offersPrefixRemoval(for: ownGame, paths: paths))
        ownGame.prefix = "/p/own"
        ownGame.runner = "Steam"
        #expect(!GameEditing.offersPrefixRemoval(for: ownGame, paths: paths))
    }

    @Test func applyWritesDraftAndKeepsUnknownFields() {
        let paths = makeTemporaryPaths()
        var original = Game(gameID: "hello", title: "Hello")
        original.playtime = 90
        original.category = .array([.string("RPG")])
        var draft = GameEditing.Draft()
        draft.title = "Hello Edited"
        draft.path = "/g/game.exe"
        draft.prefix = "/p/x/../hello/"
        draft.customRunner = true
        draft.runner = "Wine-Staging-11.21"
        draft.graphics = .dxvk
        draft.launchArguments = ["DXVK_HUD=fps", "", "mangohud"]
        draft.gameArguments = "-w"
        draft.preLaunch = "  /bin/pre.sh \n"
        draft.sdlEnabled = true
        draft.addAppEnabled = true
        draft.addAppPath = "/t/tool.exe"
        draft.addAppDelay = 3
        draft.addAppFirst = true
        let game = GameEditing.apply(draft, to: original, paths: paths)
        #expect(game.gameID == "hello")
        #expect(game.title == "Hello Edited")
        #expect(game.prefix == "/p/hello")
        #expect(game.runner == "Wine-Staging-11.21")
        #expect(game.graphics == .dxvk)
        #expect(game.launchArguments == "DXVK_HUD=fps\nmangohud")
        #expect(game.preLaunch == "/bin/pre.sh")
        #expect(game.sdlEnabled && game.addAppEnabled && game.addAppFirst)
        #expect(game.addAppDelay == "3")
        #expect(game.addAppBat == "/g/faugus-hello.bat")
        // Not edited here: kept.
        #expect(game.playtime == 90)
        #expect(game.category == .array([.string("RPG")]))

        draft.customRunner = false
        draft.graphics = .default
        let back = GameEditing.apply(draft, to: game, paths: paths)
        #expect(back.runner == "Default")
        #expect(back.graphics == nil)
    }

    @Test func formatFillsPercentD() {
        #expect(Translator.fill("used by %d other games", arguments: ["3"]) == "used by 3 other games")
    }

    @Test func presetsAndLaunchLines() throws {
        let paths = makeTemporaryPaths()
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
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        var draft = GameEditing.Draft()
        draft.title = "Celeste"
        draft.path = "504230"
        draft.prefix = paths.home + "/Faugus/celeste"
        draft.steamUser = "1034930219"
        draft.noSleep = true
        draft.sdlEnabled = true
        draft.discordRPC = true
        draft.addAppEnabled = true
        draft.addAppPath = "/x.exe"
        draft.customRunner = true
        draft.runner = "Wine-Staging-11.21"
        draft.graphics = .dxvk
        var base = Game(gameID: "celeste", title: "Celeste")
        base.mangohud = true
        let game = GameEditing.apply(draft, to: base, paths: paths)
        #expect(game.runner == "Steam")
        #expect(game.path == "504230")
        #expect(game.steamUser == "1034930219")
        #expect(game.graphics == nil)
        #expect(!game.sdlEnabled && !game.noSleep && !game.discordRPC && !game.addAppEnabled && !game.mangohud)
        #expect(game.addApp.isEmpty && game.addAppBat.isEmpty)
    }

    @Test func windowsDraftLeavesSteamUserEmpty() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        var draft = GameEditing.Draft()
        draft.title = "A"
        draft.path = "/a.exe"
        draft.prefix = "/p"
        var base = Game(gameID: "a", title: "A")
        base.steamUser = "1"
        let game = GameEditing.apply(draft, to: base, paths: paths)
        #expect(game.steamUser.isEmpty)
        #expect(game.runner == "Default")
    }

    @Test func steamSelectionIsRequired() {
        #expect(GameEditing.steamSelectionMissing(appID: ""))
        #expect(GameEditing.steamSelectionMissing(appID: "  "))
        #expect(!GameEditing.steamSelectionMissing(appID: "504230"))
    }
}
