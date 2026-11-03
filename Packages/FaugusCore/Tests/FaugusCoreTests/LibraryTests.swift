@testable import FaugusCore
import Foundation
import Testing

private func game(
    _ id: String, _ title: String, playtime: Int = 0, lastPlayed: String = "", category: JSONValue = .bool(false)
) -> Game {
    var g = Game(gameID: id, title: title)
    g.playtime = playtime
    g.lastPlayed = lastPlayed
    g.category = category
    return g
}

@Suite("Library ordering and filtering")
struct LibraryOrderingTests {
    let games = [
        game("b", "banana", playtime: 100, lastPlayed: "2026-01-02T10:00:00.000000"),
        game("a", "Apple", playtime: 500, lastPlayed: "2026-01-03T10:00:00.000000"),
        game("c", "cherry", playtime: 100),
        game("d", "Date", playtime: 0, lastPlayed: "2026-01-01T10:00:00"),
        game("e", "elder", playtime: 100, lastPlayed: "not a date"),
    ]

    @Test func alphabeticalIgnoresCase() {
        #expect(LibraryOrdering.sorted(games, mode: .alpha).map(\.gameID) == ["a", "b", "c", "d", "e"])
    }

    @Test func playtimeIsDescendingWithTitleTieBreak() {
        // 500, then the three 100s alphabetically, then 0.
        #expect(LibraryOrdering.sorted(games, mode: .playtime).map(\.gameID) == ["a", "b", "c", "e", "d"])
    }

    @Test func lastPlayedIsMostRecentFirstAndNeverPlayedLast() {
        // a (Jan 3), b (Jan 2), d (Jan 1); c and e have no usable date and sort by title.
        #expect(LibraryOrdering.sorted(games, mode: .lastplayed).map(\.gameID) == ["a", "b", "d", "c", "e"])
    }

    @Test func customOrderPutsUnlistedGamesLast() {
        let order = ["d": 0, "a": 1]
        #expect(LibraryOrdering.sorted(games, mode: .custom, customOrder: order).map(\.gameID) == [
            "d",
            "a",
            "b",
            "c",
            "e",
        ])
    }

    @Test func unknownSortValueFallsBackToAlpha() {
        #expect(SortMode(configValue: "weird") == .alpha)
        #expect(SortMode(configValue: "playtime") == .playtime)
    }

    @Test func searchIsCaseInsensitiveSubstring() {
        let r = LibraryOrdering.visible(games, mode: .alpha, search: "AN")
        #expect(r.map(\.gameID) == ["b"])
        #expect(LibraryOrdering.visible(games, mode: .alpha, search: "e").map(\.gameID) == ["a", "c", "d", "e"])
    }

    @Test func categoriesAreIgnoredWhenDisabledOrAll() {
        let g = [game("x", "X", category: .array(["RPG"])), game("y", "Y")]
        #expect(LibraryOrdering.visible(g, mode: .alpha, category: .named("RPG"), categoriesEnabled: false).count == 2)
        #expect(LibraryOrdering.visible(g, mode: .alpha, category: .all, categoriesEnabled: true).count == 2)
        #expect(LibraryOrdering.visible(g, mode: .alpha, category: .named("RPG"), categoriesEnabled: true)
            .map(\.gameID) == ["x"])
    }

    @Test func categoryValuesOfEveryShape() {
        let none = game("n", "n") // upstream stores `false`
        let str = game("s", "s", category: "RPG")
        let list = game("l", "l", category: .array(["RPG", "Indie"]))
        let literalNone = game("z", "z", category: .array(["None"]))
        #expect(none.categoryNames.isEmpty)
        #expect(str.categoryNames == ["RPG"])
        #expect(list.categoryNames == ["RPG", "Indie"])

        #expect(LibraryOrdering.gameInCategory(none, .uncategorized))
        #expect(LibraryOrdering.gameInCategory(literalNone, .uncategorized))
        #expect(!LibraryOrdering.gameInCategory(str, .uncategorized))
        #expect(LibraryOrdering.gameInCategory(str, .named("RPG")))
        #expect(LibraryOrdering.gameInCategory(list, .named("Indie")))
        // An uncategorized game "is in" the category named None, like upstream's `or [_("None")]`.
        #expect(LibraryOrdering.gameInCategory(none, .named("None")))
        #expect(!LibraryOrdering.gameInCategory(list, .named("Strategy")))
    }

    @Test func categoryCountsMatchThePicker() {
        let g = [game("x", "X", category: .array(["RPG"])), game("y", "Y"), game("z", "Z", category: "RPG")]
        #expect(LibraryOrdering.count(g, in: .all) == 3)
        #expect(LibraryOrdering.count(g, in: .named("RPG")) == 2)
        #expect(LibraryOrdering.count(g, in: .uncategorized) == 1)
    }

    @Test func categorySelectionRoundTripsThroughConfig() {
        #expect(CategorySelection(configValue: "all") == .all)
        #expect(CategorySelection(configValue: "uncategorized") == .uncategorized)
        #expect(CategorySelection(configValue: "RPG") == .named("RPG"))
        #expect(CategorySelection.named("RPG").configValue == "RPG")
        #expect(CategorySelection.all.configValue == "all")
    }
}

@Suite("Library stores", .serialized)
struct LibraryStoreTests {
    private func writeGames(_ paths: FaugusPaths, _ entries: [JSONValue]) throws {
        try JSONFile.save(.array(entries), to: paths.gamesJSON)
    }

    private func entry(_ id: String, category: JSONValue? = nil, extra: Bool = false) -> JSONValue {
        var o = JSONObject()
        o["gameid"] = .string(id)
        o["title"] = .string(id.uppercased())
        if let category {
            o["category"] = category
        }
        if extra {
            o["unknown_future_field"] = .int(7)
        }
        return .object(o)
    }

    private func categories(of id: String, _ paths: FaugusPaths) throws -> JSONValue? {
        guard case let .array(a) = try JSONFile.loadOrThrow(paths.gamesJSON) else { return nil }
        return a.compactMap(\.objectValue).first { $0["gameid"]?.stringValue == id }?["category"]
    }

    @Test func categoryListIsSortedStrippedAndValidated() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        let store = CategoryStore(paths: paths)
        let reserved = ["None", "All", "Uncategorized"]

        #expect(store.load().isEmpty)
        _ = try store.add("  zeta ", reserved: reserved)
        _ = try store.add("Alpha", reserved: reserved)
        #expect(store.load() == ["Alpha", "zeta"])
        #expect(throws: CategoryStore.Failure.duplicate) { try store.add("Alpha", reserved: reserved) }
        #expect(throws: CategoryStore.Failure.reserved) { try store.add("All", reserved: reserved) }
        #expect(throws: CategoryStore.Failure.emptyName) { try store.add("   ", reserved: reserved) }
        // Whitespace-only entries written by hand are ignored on load.
        try JSONFile.save(.array(["  x ", "", "  "]), to: paths.categoriesFile)
        #expect(store.load() == ["x"])
    }

    @Test func toggleAddsRemovesAndClearsLikeTheContextMenu() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        try writeGames(paths, [entry("a", extra: true), entry("b", category: "Legacy")])
        let assign = CategoryAssignments(paths: paths)

        try assign.toggle(gameID: "a", category: "RPG")
        #expect(try categories(of: "a", paths) == .array(["RPG"]))
        try assign.toggle(gameID: "a", category: "Indie")
        #expect(try categories(of: "a", paths) == .array(["RPG", "Indie"]))
        try assign.toggle(gameID: "a", category: "RPG")
        #expect(try categories(of: "a", paths) == .array(["Indie"]))
        try assign.toggle(gameID: "a", category: "None")
        #expect(try categories(of: "a", paths) == nil) // key removed, like upstream's pop

        // A legacy string value is treated as a one-element list.
        try assign.toggle(gameID: "b", category: "Extra")
        #expect(try categories(of: "b", paths) == .array(["Legacy", "Extra"]))

        // Unknown fields survive.
        guard case let .array(all) = try JSONFile.loadOrThrow(paths.gamesJSON) else { return }
        #expect(all.first?.objectValue?["unknown_future_field"] == .int(7))
    }

    @Test func renameAndRemoveRewriteEveryGame() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        try writeGames(paths, [
            entry("a", category: "RPG"), entry("b", category: .array(["RPG", "Indie"])),
            entry("c", category: .array(["Indie", "Rpg2", "RPG"])), entry("d"),
        ])
        let store = CategoryStore(paths: paths)
        try store.save(["Indie", "RPG"])

        _ = try store.rename("RPG", to: "Rpg2", reserved: [])
        #expect(try categories(of: "a", paths) == .array(["Rpg2"])) // string becomes a list
        #expect(try categories(of: "b", paths) == .array(["Rpg2", "Indie"]))
        #expect(try categories(of: "c", paths) == .array(["Indie", "Rpg2"])) // de-duplicated
        #expect(try categories(of: "d", paths) == nil)
        #expect(store.load() == ["Indie", "Rpg2"])

        _ = try store.remove("Indie")
        #expect(try categories(of: "b", paths) == .array(["Rpg2"]))
        #expect(try categories(of: "c", paths) == .array(["Rpg2"]))
        _ = try store.remove("Rpg2")
        #expect(try categories(of: "a", paths) == nil)
        #expect(try categories(of: "b", paths) == nil)
        #expect(store.load().isEmpty)
        #expect(throws: CategoryStore.Failure.missing) { try store.remove("Nope") }
    }

    @Test func customOrderMovesLikeADragAndForgetsDeletedGames() throws {
        #expect(CustomOrderStore.move(ordered: ["a", "b", "c", "d"], source: "d", target: "b") == [
            "a": 0,
            "d": 1,
            "b": 2,
            "c": 3,
        ])
        #expect(CustomOrderStore.move(ordered: ["a", "b", "c"], source: "a", target: "c") == ["b": 0, "c": 1, "a": 2])
        #expect(CustomOrderStore.move(ordered: ["a", "b"], source: "a", target: "a") == nil)
        #expect(CustomOrderStore.move(ordered: ["a", "b"], source: "a", target: "zzz") == nil)

        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        let store = CustomOrderStore(paths: paths)
        #expect(store.load().isEmpty)
        try store.save(["a": 0, "b": 1, "c": 2])
        #expect(store.load() == ["a": 0, "b": 1, "c": 2])
        try store.remove(gameID: "b")
        #expect(store.load() == ["a": 0, "c": 2])
    }

    @Test func recentRunFilesKeepFiveNewestAndSkipMissingOnes() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        let dir = paths.home + "/files"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var files: [String] = []
        for i in 0 ..< 7 {
            let f = dir + "/f\(i).exe"
            FileManager.default.createFile(atPath: f, contents: Data())
            files.append(f)
        }
        let recent = RecentRunFiles(paths: paths)
        for f in files {
            try recent.record(gameID: "g", file: f)
        }
        #expect(recent.files(gameID: "g") == [files[6], files[5], files[4], files[3], files[2]])

        // Re-running a file moves it to the front without duplicating it.
        try recent.record(gameID: "g", file: files[3])
        #expect(recent.files(gameID: "g").first == files[3])
        #expect(Set(recent.files(gameID: "g")).count == 5)

        // Deleted files disappear from the menu but stay on record.
        try FileManager.default.removeItem(atPath: files[3])
        #expect(!recent.files(gameID: "g").contains(files[3]))

        try recent.record(gameID: "other", file: files[0])
        try recent.clear(gameID: "g")
        #expect(recent.files(gameID: "g").isEmpty)
        #expect(recent.files(gameID: "other") == [files[0]])
    }
}
