import Foundation

/// Upstream's `format_playtime` / `format_playtime_display` / `format_last_played`.
public enum GameFormatting {
    /// `nil` for under a minute (upstream returns `None` and the caller adds "Less than a minute").
    public static func playtime(seconds: Int, _ t: Translator) -> String? {
        guard seconds > 0 else { return nil }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours == 0 && minutes == 0 { return nil }
        var parts: [String] = []
        if hours > 0 {
            parts.append(Translator.fill(t(hours == 1 ? "{} hour" : "{} hours"), args: [String(hours)]))
        }
        if minutes > 0 {
            parts.append(Translator.fill(t(minutes == 1 ? "{} minute" : "{} minutes"), args: [String(minutes)]))
        }
        return parts.joined(separator: " ")
    }

    /// `nil` when nothing has been played (upstream hides the line).
    public static func playtimeDisplay(seconds: Int, _ t: Translator) -> String? {
        guard seconds > 0 else { return nil }
        return playtime(seconds: seconds, t) ?? t("Less than a minute")
    }

    /// Python's `datetime.fromisoformat` for the naive local timestamps upstream writes.
    public static func parseISO(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        let formats = ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss"]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for format in formats {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    public static func lastPlayed(iso: String, now: Date = Date(), _ t: Translator) -> String? {
        guard let start = parseISO(iso) else { return nil }
        let seconds = max(0, now.timeIntervalSince(start))
        func n(_ msgid: String, _ v: Int) -> String { Translator.fill(t(msgid), args: [String(v)]) }

        if seconds < 60 { return t("Just now") }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return minutes == 1 ? t("A minute ago") : n("{} minutes ago", minutes) }
        let hours = Int(seconds / 3600)
        if hours < 24 { return hours == 1 ? t("An hour ago") : n("{} hours ago", hours) }
        let days = Int(seconds / 86400)
        if days < 7 { return days == 1 ? t("Yesterday") : n("{} days ago", days) }
        let weeks = days / 7
        if weeks < 4 { return weeks == 1 ? t("A week ago") : n("{} weeks ago", weeks) }
        let months = days / 30
        if months < 12 { return months == 1 ? t("A month ago") : n("{} months ago", months) }
        let years = days / 365
        return years == 1 ? t("A year ago") : n("{} years ago", years)
    }
}
