@testable import FaugusCore
import Foundation
import Testing

@Suite("Game formatting")
struct FormattingTests {
    let translate = Translator.identity

    @Test func playtime() {
        #expect(GameFormatting.playtime(seconds: 0, translate) == nil)
        #expect(GameFormatting.playtime(seconds: 59, translate) == nil)
        #expect(GameFormatting.playtimeDisplay(seconds: 59, translate) == "Less than a minute")
        #expect(GameFormatting.playtimeDisplay(seconds: 0, translate) == nil)
        #expect(GameFormatting.playtime(seconds: 60, translate) == "1 minute")
        #expect(GameFormatting.playtime(seconds: 3600, translate) == "1 hour")
        #expect(GameFormatting.playtime(seconds: 7260, translate) == "2 hours 1 minute")
        #expect(GameFormatting.playtime(seconds: 3600 * 12 + 600, translate) == "12 hours 10 minutes")
    }

    @Test func lastPlayed() {
        let now = GameFormatting.parseISO("2026-11-03T12:00:00")!
        func ago(_ secondsAgo: Double) -> String? {
            let date = now.addingTimeInterval(-secondsAgo)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
            return GameFormatting.lastPlayed(iso: formatter.string(from: date), now: now, translate)
        }
        #expect(ago(10) == "Just now")
        #expect(ago(60) == "A minute ago")
        #expect(ago(5 * 60) == "5 minutes ago")
        #expect(ago(3600) == "An hour ago")
        #expect(ago(3 * 3600) == "3 hours ago")
        #expect(ago(86400) == "Yesterday")
        #expect(ago(3 * 86400) == "3 days ago")
        #expect(ago(7 * 86400) == "A week ago")
        #expect(ago(21 * 86400) == "3 weeks ago")
        #expect(ago(30 * 86400) == "A month ago")
        #expect(ago(90 * 86400) == "3 months ago")
        #expect(ago(365 * 86400) == "A year ago")
        #expect(ago(800 * 86400) == "2 years ago")
        #expect(GameFormatting.lastPlayed(iso: "", now: now, translate) == nil)
        #expect(GameFormatting.lastPlayed(iso: "garbage", now: now, translate) == nil)
    }
}

@Suite("Session formatting")
struct SessionFormattingTests {
    @Test func playingForAndCategoryLine() {
        let now = Date()
        #expect(GameFormatting
            .playingFor(start: now.addingTimeInterval(-20), now: now, .identity) == "Less than a minute")
        #expect(GameFormatting
            .playingFor(start: now.addingTimeInterval(-3700), now: now, .identity) == "1 hour 1 minute")
        #expect(GameFormatting
            .playingFor(start: now.addingTimeInterval(60), now: now, .identity) == "Less than a minute")
        #expect(GameFormatting.categoryLine(["zeta", "Alpha", "beta"]) == "Alpha, beta, zeta")
        #expect(GameFormatting.categoryLine([]) == "")
    }

    @Test func processStartDateIsKnownForOurselvesAndNilForDeadPIDs() {
        let started = ProcessScanner.startDate(of: getpid())
        #expect(started != nil)
        #expect(started! <= Date())
        #expect(started! > Date().addingTimeInterval(-86400 * 365))
        #expect(ProcessScanner.startDate(of: 99_999_999) == nil)
    }
}
