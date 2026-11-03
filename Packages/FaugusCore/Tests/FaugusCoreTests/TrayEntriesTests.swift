@testable import FaugusCore
import Testing

@Suite("Tray entries")
struct TrayEntriesTests {
    private func game(_ gameID: String, title: String? = nil, lastPlayed: String) -> Game {
        var game = Game(gameID: gameID, title: title ?? gameID)
        game.lastPlayed = lastPlayed
        return game
    }

    @Test func listsTheFiveMostRecentlyPlayedGamesNewestFirst() {
        let games = (1 ... 7).map { game("game\($0)", lastPlayed: "2026-01-0\($0) 10:00:00") }
        let recent = TrayEntries.recentGames(from: games)
        #expect(recent.map(\.gameID) == ["game7", "game6", "game5", "game4", "game3"])
    }

    @Test func skipsGamesThatWereNeverPlayed() {
        let games = [game("played", lastPlayed: "2026-02-01 08:00:00"), game("fresh", lastPlayed: "")]
        #expect(TrayEntries.recentGames(from: games).map(\.gameID) == ["played"])
    }

    @Test func equalTimestampsOrderByGameIDDescendingLikeUpstream() {
        let games = [
            game("alpha", lastPlayed: "2026-03-01 09:00:00"),
            game("omega", lastPlayed: "2026-03-01 09:00:00"),
        ]
        #expect(TrayEntries.recentGames(from: games).map(\.gameID) == ["omega", "alpha"])
    }

    @Test func fallsBackToTheGameIDWhenTheTitleIsEmpty() {
        let games = [game("untitled", title: "", lastPlayed: "2026-03-01 09:00:00")]
        #expect(TrayEntries.recentGames(from: games).first?.title == "untitled")
    }
}
