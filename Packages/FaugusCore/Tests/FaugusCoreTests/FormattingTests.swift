import Foundation
import Testing

@testable import FaugusCore

@Suite("Game formatting")
struct FormattingTests {
    let t = Translator.identity

    @Test func playtime() {
        #expect(GameFormatting.playtime(seconds: 0, t) == nil)
        #expect(GameFormatting.playtime(seconds: 59, t) == nil)
        #expect(GameFormatting.playtimeDisplay(seconds: 59, t) == "Less than a minute")
        #expect(GameFormatting.playtimeDisplay(seconds: 0, t) == nil)
        #expect(GameFormatting.playtime(seconds: 60, t) == "1 minute")
        #expect(GameFormatting.playtime(seconds: 3600, t) == "1 hour")
        #expect(GameFormatting.playtime(seconds: 7260, t) == "2 hours 1 minute")
        #expect(GameFormatting.playtime(seconds: 3600 * 12 + 600, t) == "12 hours 10 minutes")
    }

    @Test func lastPlayed() {
        let now = GameFormatting.parseISO("2026-11-03T12:00:00")!
        func ago(_ s: Double) -> String? {
            let d = now.addingTimeInterval(-s)
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
            return GameFormatting.lastPlayed(iso: f.string(from: d), now: now, t)
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
        #expect(GameFormatting.lastPlayed(iso: "", now: now, t) == nil)
        #expect(GameFormatting.lastPlayed(iso: "garbage", now: now, t) == nil)
    }
}
