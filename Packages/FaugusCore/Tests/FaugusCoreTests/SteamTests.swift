import CoreGraphics
@testable import FaugusCore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite("Steam", .serialized)
struct SteamTests {
    private func makeJPEG(_ side: Int) -> Data {
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let jpegData = NSMutableData()
        let destination = CGImageDestinationCreateWithData(jpegData, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return jpegData as Data
    }

    // MARK: VDF

    @Test func parsesNestedObjectsAndComments() throws {
        let text = """
        // comment
        "libraryfolders"
        {
            "0"
            {
                "path"      "/Users/me/Library/Application Support/Steam"
                "apps"
                {
                    "228980"    "1234"
                }
            }
            "1" { "path" "/Volumes/Games/SteamLibrary" }
        }
        """
        let vdf = try #require(VDF.parse(text))
        let folders = try #require(vdf["libraryfolders"])
        #expect(folders["0"]?["path"]?.string == "/Users/me/Library/Application Support/Steam")
        #expect(folders["1"]?["path"]?.string == "/Volumes/Games/SteamLibrary")
        #expect(vdf.path("LibraryFolders", "0", "apps", "228980")?.string == "1234")
        #expect(folders.entries.map(\.key) == ["0", "1"])
    }

    @Test func parsesEscapesBareTokensAndRepeatedKeys() throws {
        let vdf = try #require(VDF
            .parse("\"a\" \"x\\\\y \\\"q\\\"\"\n\"a\" \"second\"\nbare token\n\"BOM\" \"\u{FEFF}v\""))
        #expect(vdf["a"]?.string == "second")
        #expect(vdf["bare"]?.string == "token")
    }

    @Test func badInputNeverCrashes() {
        for text in [
            "",
            "{",
            "}",
            "\"a\"",
            "\"a\" {",
            "\"a\" { \"b\" ",
            "\"a\" { \"b\" \"c\" } }",
            "\"",
            "\"a\" \"b",
            String(repeating: "\"a\" {", count: 500),
        ] {
            _ = VDF.parse(text)
        }
        #expect(VDF.parse("}") == nil)
        #expect(VDF.parse("\"a\" { \"b\" \"c\" } }") == nil)
    }

    // MARK: Library

    private func makeSteam(_ paths: FaugusPaths) throws -> SteamLibrary {
        let fileManager = FileManager.default
        let steam = SteamLibrary(home: paths.home)
        let root = steam.root
        let second = paths.home + "/Disk/SteamLibrary"
        for directory in [
            root + "/steamapps/common/Celeste", root + "/config", root + "/userdata/1034930219/config",
            root + "/userdata/42/config", root + "/userdata/0/config", root + "/userdata/notanumber",
            second + "/steamapps/common/Hades", root + "/appcache/librarycache/504230/abc",
        ] {
            try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }

        func write(_ path: String, _ text: String) throws {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        }
        try write(root + "/steamapps/libraryfolders.vdf", """
        "libraryfolders" {
          "0" { "path" "\(root)" }
          "1" { "path" "\(second)" }
        }
        """)
        // 76561198995195947 = 1034930219 + base
        try write(root + "/config/loginusers.vdf", """
        "users" {
          "76561198995195947" { "PersonaName" "Tomi" "AccountName" "tomi" }
          "76561197960265770" { "PersonaName" "alice" }
        }
        """)
        try write(root + "/steamapps/appmanifest_504230.acf", """
        "AppState" { "appid" "504230" "name" "Celeste" "installdir" "Celeste" "LastOwner" "76561198995195947" }
        """)
        try write(second + "/steamapps/appmanifest_1145360.acf", """
        "AppState" { "appid" "1145360" "name" "Hades" "installdir" "Hades" "LastOwner" "76561197960265770" }
        """)
        try write(root + "/steamapps/appmanifest_1493710.acf", """
        "AppState" { "appid" "1493710" "name" "Proton Experimental" "installdir" "Proton" "LastOwner" "76561198995195947" }
        """)
        try write(root + "/steamapps/appmanifest_9.acf", "\"AppState\" { \"appid\" \"9\" \"installdir\" \"NoName\" }")
        try write(root + "/userdata/1034930219/config/localconfig.vdf", """
        "UserLocalConfigStore" {
          "Software" { "Valve" { "Steam" { "apps" {
            "504230" { "Playtime" "125" "LastPlayed" "1" }
            "1145360" { "Playtime" "30" }
          } } } }
          "FamilyGroup" { "members" { "0" { "accountid" "42" } } }
        }
        """)
        try write(root + "/userdata/42/config/localconfig.vdf", """
        "UserLocalConfigStore" { "Software" { "Valve" { "Steam" { "apps" { "504230" { "Playtime" "10" } } } } } }
        """)
        return steam
    }

    @Test func listsUsersLibrariesAndGames() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        let steam = try makeSteam(paths)

        #expect(steam.accountIDs() == ["1034930219", "42"])
        let users = steam.users()
        #expect(users.map(\.name) == ["alice", "Tomi"])
        #expect(users.last?.label == "Tomi (1034930219)")
        #expect(users.first?.label == "alice (42)")
        #expect(steam.libraryFolders() == [steam.root, paths.home + "/Disk/SteamLibrary"])

        let all = steam.installedGames()
        #expect(all.map(\.name) == ["Celeste", "Hades", "Proton Experimental"])
        #expect(steam.pickerGames(accountID: nil).map(\.name) == ["Celeste", "Hades"])
        #expect(steam.pickerGames(accountID: "all").map(\.appID) == ["504230", "1145360"])
    }

    @Test func symlinkedLibraryIsNotListedTwice() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        let steam = try makeSteam(paths)
        let alias = paths.home + "/steam-alias"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: steam.root)
        try Data("\"libraryfolders\" { \"0\" { \"path\" \"\(alias)\" } }".utf8)
            .write(to: URL(fileURLWithPath: steam.root + "/steamapps/libraryfolders.vdf"))
        #expect(steam.libraryFolders().count == 1)
        #expect(steam.installedGames().map(\.name) == ["Celeste", "Proton Experimental"])
    }

    @Test func accountFilterFollowsOwnershipAndFamilySharing() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        let steam = try makeSteam(paths)
        // Tomi owns Celeste and Proton; Hades is owned by account 42, a family member of Tomi.
        #expect(steam.pickerGames(accountID: "1034930219").map(\.name) == ["Celeste", "Hades"])
        // Account 42 has no family group in its own config: only what it owns itself.
        #expect(steam.pickerGames(accountID: "42").map(\.name) == ["Hades"])
    }

    @Test func playtimeAndInstallFolder() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        let steam = try makeSteam(paths)
        #expect(steam.playtimeMinutes(appID: "504230", accountID: "1034930219") == 125)
        #expect(steam.playtimeMinutes(appID: "504230", accountID: nil) == 135)
        #expect(steam.playtimeMinutes(appID: "504230", accountID: "all") == 135)
        #expect(steam.playtimeMinutes(appID: "999", accountID: nil) == 0)
        #expect(steam.installFolder(appID: "504230") == steam.root + "/steamapps/common/Celeste")
        #expect(steam.installFolder(appID: "1145360") == paths.home + "/Disk/SteamLibrary/steamapps/common/Hades")
        #expect(steam.installFolder(appID: "1493710") == nil) // folder missing
        #expect(steam.installFolder(appID: "nope") == nil)
    }

    @Test func installDirectoryCannotEscapeTheLibrary() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        let steam = try makeSteam(paths)
        try Data("\"AppState\" { \"name\" \"Evil\" \"installdir\" \"../../../..\" }".utf8)
            .write(to: URL(fileURLWithPath: steam.root + "/steamapps/appmanifest_666.acf"))
        #expect(steam.installFolder(appID: "666") == nil)
    }

    @Test func iconIsTheSmallestNonHeaderImage() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        let steam = try makeSteam(paths)
        let artworkDirectory = steam.root + "/appcache/librarycache/504230"
        func writeJPEG(_ relativePath: String, _ side: Int) throws {
            try makeJPEG(side).write(to: URL(fileURLWithPath: artworkDirectory + "/" + relativePath))
        }
        try writeJPEG("header.jpg", 8)
        try writeJPEG("library_600x900.jpg", 8)
        try writeJPEG("abc/big.jpg", 64)
        try writeJPEG("abc/icon.jpg", 16)
        try Data("not an image".utf8).write(to: URL(fileURLWithPath: artworkDirectory + "/broken.jpg"))
        #expect(steam.iconPath(appID: "504230") == artworkDirectory + "/abc/icon.jpg")
        #expect(steam.iconPath(appID: "nothing") == nil)
    }

    @Test func steamInstalledDetection() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        let steam = SteamLibrary(home: paths.home)
        #expect(!steam.isSteamInstalled(home: paths.home, bundles: []))
        try FileManager.default.createDirectory(atPath: steam.root, withIntermediateDirectories: true)
        #expect(steam.isSteamInstalled(home: paths.home, bundles: []))
    }

    // MARK: Launch

    @Test func launchURLs() {
        #expect(SteamLaunch.url(appID: "504230", gameArguments: "") == "steam://rungameid/504230")
        #expect(SteamLaunch.url(appID: " 504230 ", gameArguments: "  ") == "steam://rungameid/504230")
        #expect(SteamLaunch
            .url(appID: "504230", gameArguments: "-windowed -w 1280") == "steam://run/504230//-windowed%20-w%201280/")
        #expect(SteamLaunch.url(appID: "504230", gameArguments: "a/b?c") == "steam://run/504230//a%2Fb%3Fc/")
        #expect(SteamLaunch.url(appID: "", gameArguments: "") == nil)
        #expect(SteamLaunch.url(appID: "12 34", gameArguments: "") == nil)
        #expect(SteamLaunch.url(appID: "../x", gameArguments: "") == nil)
    }

    @Test func supervisorHandsSteamGamesToSteam() async throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        _ = try makeSteam(paths)
        var game = Game(gameID: "celeste", title: "Celeste")
        game.runner = "Steam"
        game.path = "504230"
        game.gameArguments = "-windowed"
        try GamesStore(paths: paths).save(games: [game])

        final class Box: @unchecked Sendable { var urls: [String] = [] }
        let box = Box()
        var options = SupervisorOptions()
        options.steamSplashDuration = .milliseconds(10)
        options.openSteamURL = { box.urls.append($0)
            return true
        }
        let events = EventLog()
        let failure = await GameSupervisor(paths: paths, gameID: "celeste", options: options) { events.add($0) }.run()
        #expect(failure == nil)
        #expect(box.urls == ["steam://run/504230//-windowed/"])
        #expect(events.all.contains(.running(pid: 0)))

        let saved = try #require(try GamesStore(paths: paths).loadAll().first)
        #expect(saved.lastPlayed.contains("T"))
        #expect(saved.playtime == 0)
        #expect(RunningGames(paths: paths).load().isEmpty)
        // No Wine, no prefix, no log directory.
        #expect(!FileManager.default.fileExists(atPath: paths.gameLogsDirectory(gameID: "celeste")))
        #expect(!FileManager.default.fileExists(atPath: paths.home + "/Faugus"))
    }

    @Test func supervisorRejectsABadAppIDAndFailedOpen() async throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        _ = try makeSteam(paths)
        var badGame = Game(gameID: "bad", title: "Bad")
        badGame.runner = "Steam"
        badGame.path = "not-an-id"
        var okGame = Game(gameID: "ok", title: "Ok")
        okGame.runner = "Steam"
        okGame.path = "1"
        try GamesStore(paths: paths).save(games: [badGame, okGame])
        var options = SupervisorOptions()
        options.steamSplashDuration = .zero
        options.openSteamURL = { _ in false }
        let badAppIDFailure = await GameSupervisor(paths: paths, gameID: "bad", options: options).run()
        #expect(badAppIDFailure == .launchFailed("\"not-an-id\" is not a Steam app id"))
        let failedOpenFailure = await GameSupervisor(paths: paths, gameID: "ok", options: options).run()
        #expect(failedOpenFailure == .launchFailed("Could not start Steam"))
    }
}
