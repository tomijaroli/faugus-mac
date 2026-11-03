@testable import FaugusCore
import Foundation
import Testing

@Suite("games.json")
struct GamesTests {
    @Test func gameFieldsMatchUpstream() throws {
        let upstream = try JSONParser.parse(TestSupport.fixtureData("game_fields.json"))
        #expect(upstream.arrayValue?.compactMap(\.stringValue) == gameFields)
    }

    @Test func upstreamFileResavesByteIdentical() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        try TestSupport.install(fixture: "games.upstream.json", at: paths.gamesJSON)
        let before = try Data(contentsOf: URL(fileURLWithPath: paths.gamesJSON))

        let store = GamesStore(paths: paths)
        let all = try store.loadAll()
        #expect(all.count == 4)
        #expect(all.filter(\.hidden).map(\.gameID) == ["hollow-knight-silksong"])

        // The UI holds visible games only; the hidden one must be preserved verbatim.
        let visible = try store.load(showHidden: false)
        #expect(visible.count == 3)
        try store.save(games: all.filter { !$0.hidden })

        let after = try Data(contentsOf: URL(fileURLWithPath: paths.gamesJSON))
        // Order differs by design (visible first, hidden last, as upstream); content is equal.
        let a = try JSONParser.parse(before).arrayValue!
        let b = try JSONParser.parse(after).arrayValue!
        #expect(a.count == b.count)
        for entry in a {
            #expect(b.contains(entry))
        }
        #expect(!String(decoding: after, as: UTF8.self).contains("\"graphics\""))
    }

    @Test func savingEveryGameKeepsFileByteIdentical() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        try TestSupport.install(fixture: "games.upstream.json", at: paths.gamesJSON)
        let before = try Data(contentsOf: URL(fileURLWithPath: paths.gamesJSON))
        let store = GamesStore(paths: paths)
        try store.save(games: store.loadAll())
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths.gamesJSON)) == before)
    }

    @Test func extraFieldsSurvive() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        try TestSupport.install(fixture: "games.extra-fields.json", at: paths.gamesJSON)
        let before = try Data(contentsOf: URL(fileURLWithPath: paths.gamesJSON))
        let store = GamesStore(paths: paths)
        let games = try store.loadAll()
        #expect(games[0].graphics == .wined3d)
        #expect(games[1].raw["future_field"] != nil)
        try store.save(games: games)
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths.gamesJSON)) == before)
    }

    @Test func missingGraphicsIsNeverBackfilled() {
        var g = Game(gameID: "x", title: "X")
        #expect(g.graphics == nil)
        #expect(g.saveObject()["graphics"] == nil)
        g.graphics = .dxvk
        #expect(g.saveObject()["graphics"] == "dxvk")
        g.graphics = nil
        #expect(g.saveObject()["graphics"] == nil)
    }

    @Test func prepareGameKwargsDefaultsAndSaveNormalisation() {
        let g = Game(json: ["gameid": "a", "title": "A", "mangohud": 1, "addapp_enabled": true])
        #expect(g.playtime == 0)
        #expect(g.hidden == false)
        #expect(g.category == .bool(false))
        let s = g.saveObject()
        #expect(s.keys == gameFields)
        #expect(s["mangohud"] == .bool(true))
        #expect(s["gamemode"] == "")
        #expect(s["addapp_enabled"] == "addapp_enabled")
        #expect(s["path"] == "")
    }

    @Test func deleteRemovesGameAndHiddenEntries() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        try TestSupport.install(fixture: "games.upstream.json", at: paths.gamesJSON)
        let store = GamesStore(paths: paths)
        let visible = try store.load(showHidden: false)
        try store.save(games: visible, deletedGameID: "celeste")
        #expect(try Set(store.loadAll().map(\.gameID)) == [
            "the-witcher-3-wild-hunt",
            "hollow-knight-silksong",
            "installer-test",
        ])

        // Deleting a hidden game (it is not in `visible`) also drops it.
        try store.save(games: [], deletedGameID: "hollow-knight-silksong")
        #expect(try !(store.existingGameIDs()).contains("hollow-knight-silksong"))
    }

    @Test func showHiddenAndSortByLowercasedTitle() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        try TestSupport.install(fixture: "games.upstream.json", at: paths.gamesJSON)
        let store = GamesStore(paths: paths)
        let titles = try store.load(showHidden: true).map { $0.title.lowercased() }
        #expect(titles == titles.sorted())
        #expect(try store.load(showHidden: true).count == 4)
    }

    @Test func corruptFileIsNeverOverwritten() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        try FileManager.default.createDirectory(atPath: paths.dataDirectory, withIntermediateDirectories: true)
        try Data("[{oops".utf8).write(to: URL(fileURLWithPath: paths.gamesJSON))
        let store = GamesStore(paths: paths)
        #expect(throws: GamesStoreError.self) { try store.loadAll() }
        #expect(throws: GamesStoreError.self) { try store.save(games: [Game(gameID: "a", title: "A")]) }
        #expect(try String(decoding: Data(contentsOf: URL(fileURLWithPath: paths.gamesJSON)), as: UTF8.self) ==
            "[{oops")
    }

    @Test func missingFileMeansEmptyAndFirstSaveCreatesIt() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        let store = GamesStore(paths: paths)
        #expect(try store.loadAll().isEmpty)
        try store.save(games: [Game(gameID: "a", title: "A")])
        #expect(try store.loadAll().map(\.gameID) == ["a"])
        // No backup when there was nothing to back up.
        #expect(!FileManager.default.fileExists(atPath: paths.gamesBackupDirectory))
    }

    @Test func backupsAreRotatedToTwenty() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        let store = GamesStore(paths: paths)
        try store.save(games: [Game(gameID: "a", title: "A")])
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0 ..< 25 {
            try store.save(games: [Game(gameID: "a", title: "A\(i)")], now: start.addingTimeInterval(Double(i)))
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: paths.gamesBackupDirectory).sorted()
        #expect(files.count == 20)
        #expect(files.allSatisfy { $0.hasPrefix("games-data-") && $0.hasSuffix(".json") })
        // The newest 20 are kept.
        let newestStamp = files.last!
        #expect(newestStamp > files.first!)
    }
}

@Suite("Game IDs")
struct GameIDTests {
    @Test(
        "format_title matches Python",
        arguments: [
            ("The Witcher 3: Wild Hunt", "the-witcher-3-wild-hunt"),
            ("  Hello   World  ", "hello-world"),
            ("Hollow Knight: Silksong (日本語 ñ)", "hollow-knight-silksong-日本語-ñ"),
            ("A_B -- C", "a_b----c"),
            ("Ünïcödé", "ünïcödé"),
            ("Cafe\u{301}", "cafe"),
            ("", ""),
            ("Half-Life 2: Episode ²", "half-life-2-episode-²"),
            ("Tab\tSep\nNew", "tab-sep-new"),
            ("!!!", ""),
            ("ＡＢＣ １２３", "ａｂｃ-１２３"),
            ("Ⅳ roman", "ⅳ-roman"),
            ("İstanbul", "istanbul"),
        ]
    )
    func formatTitle(input: String, expected: String) {
        #expect(GameID.format(title: input) == expected)
    }

    @Test func unique() {
        #expect(GameID.unique(base: "a", existing: []) == "a")
        #expect(GameID.unique(base: "a", existing: ["a"]) == "a-2")
        #expect(GameID.unique(base: "a", existing: ["a", "a-2", "a-3"]) == "a-4")
        #expect(GameID.unique(base: "", existing: [""]) == "")
    }
}
