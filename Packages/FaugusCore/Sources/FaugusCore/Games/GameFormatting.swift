import Foundation

/// Upstream's `format_playtime` / `format_playtime_display` / `format_last_played`.
public enum GameFormatting {
    /// `nil` for under a minute (upstream returns `None` and the caller adds "Less than a minute").
    public static func playtime(seconds: Int, _ translate: Translator) -> String? {
        guard seconds > 0 else { return nil }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours == 0, minutes == 0 {
            return nil
        }
        var parts: [String] = []
        if hours > 0 {
            parts.append(Translator.fill(translate(hours == 1 ? "{} hour" : "{} hours"), arguments: [String(hours)]))
        }
        if minutes > 0 {
            parts.append(Translator.fill(
                translate(minutes == 1 ? "{} minute" : "{} minutes"),
                arguments: [String(minutes)]
            ))
        }
        return parts.joined(separator: " ")
    }

    /// `nil` when nothing has been played (upstream hides the line).
    public static func playtimeDisplay(seconds: Int, _ translate: Translator) -> String? {
        guard seconds > 0 else { return nil }
        return playtime(seconds: seconds, translate) ?? translate("Less than a minute")
    }

    /// Python's `datetime.fromisoformat` for the naive local timestamps upstream writes.
    public static func parseISO(_ timestamp: String) -> Date? {
        guard !timestamp.isEmpty else { return nil }
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss.SSSSSS",
            "yyyy-MM-dd HH:mm:ss",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: timestamp) {
                return date
            }
        }
        return nil
    }

    public static func lastPlayed(iso: String, now: Date = Date(), _ translate: Translator) -> String? {
        guard let start = parseISO(iso) else { return nil }
        let seconds = max(0, now.timeIntervalSince(start))
        func localizedCount(_ messageID: String, _ count: Int) -> String {
            Translator.fill(translate(messageID), arguments: [String(count)])
        }

        if seconds < 60 {
            return translate("Just now")
        }
        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return minutes == 1 ? translate("A minute ago") : localizedCount("{} minutes ago", minutes)
        }
        let hours = Int(seconds / 3600)
        if hours < 24 {
            return hours == 1 ? translate("An hour ago") : localizedCount("{} hours ago", hours)
        }
        let days = Int(seconds / 86400)
        if days < 7 {
            return days == 1 ? translate("Yesterday") : localizedCount("{} days ago", days)
        }
        let weeks = days / 7
        if weeks < 4 {
            return weeks == 1 ? translate("A week ago") : localizedCount("{} weeks ago", weeks)
        }
        let months = days / 30
        if months < 12 {
            return months == 1 ? translate("A month ago") : localizedCount("{} months ago", months)
        }
        let years = days / 365
        return years == 1 ? translate("A year ago") : localizedCount("{} years ago", years)
    }

    /// `format_playing_for`: the length of the running session.
    public static func playingFor(start: Date, now: Date = Date(), _ translate: Translator) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(start)))
        return playtime(seconds: seconds, translate) ?? translate("Less than a minute")
    }

    /// The overview panel's category line: names sorted case-insensitively.
    public static func categoryLine(_ names: [String]) -> String {
        names.sorted { $0.lowercased() < $1.lowercased() }.joined(separator: ", ")
    }
}
