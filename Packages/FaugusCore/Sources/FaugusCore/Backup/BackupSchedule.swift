import Foundation

/// `should_run_backup` from `backup_daemon.py`.
public enum BackupSchedule {
    public static let defaultTargetTime = "00:00"

    /// `backup-frequency` values plus the Backup window's Disabled choice (which writes auto off).
    public static let frequencies = ["disabled", "daily", "weekly", "monthly"]

    public static let weekdays = [
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
    ]

    public static func parseTargetTime(_ text: String) -> (hour: Int, minute: Int) {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0 ... 23).contains(hour), (0 ... 59).contains(minute)
        else { return (0, 0) }
        return (hour, minute)
    }

    public static func formatTargetTime(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    /// True when automatic backup is on and `now` has passed the next scheduled slot after
    /// `backup-last-auto-date`.
    public static func shouldRun(
        configuration: FaugusConfig,
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Bool {
        guard configuration.bool("backup-auto-enabled") else { return false }

        // Upstream's fallback is datetime(2000, 1, 1).
        let last = parseLastBackup(
            configuration.string("backup-last-auto-date"), timeZone: calendar.timeZone
        )
            ?? calendar.date(from: DateComponents(year: 2000, month: 1, day: 1))
            ?? Date.distantPast

        let time = parseTargetTime(configuration.string("backup-target-time", default: defaultTargetTime))
        let frequency = configuration.string("backup-frequency", default: "daily")
        let targetDay = configuration.int("backup-target-day", default: 0)

        let today = calendar.startOfDay(for: now)
        let targetDate: Date
        if frequency == "weekly" {
            let daysAgo = (pythonWeekday(now, calendar: calendar) - targetDay + 7) % 7
            targetDate = calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
        } else if frequency == "monthly" {
            targetDate = lastMonthlyTarget(today: today, targetDay: targetDay, calendar: calendar)
        } else {
            targetDate = today
        }

        var components = calendar.dateComponents([.year, .month, .day], from: targetDate)
        components.hour = time.hour
        components.minute = time.minute
        components.second = 0
        let targetDateTime = calendar.date(from: components) ?? targetDate

        return now >= targetDateTime && last < targetDateTime
    }

    /// Python `date.weekday()`: Monday = 0 … Sunday = 6.
    public static func pythonWeekday(_ date: Date, calendar: Calendar) -> Int {
        let weekday = calendar.component(.weekday, from: date) // Sunday = 1
        return (weekday + 5) % 7
    }

    /// `get_last_monthly_target`: this month's day if it has already arrived, otherwise last month's.
    public static func lastMonthlyTarget(today: Date, targetDay: Int, calendar: Calendar) -> Date {
        func clamped(_ date: Date, day: Int) -> Date {
            let range = calendar.range(of: .day, in: .month, for: date)
            let lastDay = range?.count ?? 31
            var components = calendar.dateComponents([.year, .month], from: date)
            components.day = min(max(day, 1), lastDay)
            return calendar.date(from: components) ?? date
        }

        let currentMonthTarget = clamped(today, day: targetDay)
        if today >= currentMonthTarget {
            return currentMonthTarget
        }
        guard let previousMonth = calendar.date(byAdding: .month, value: -1, to: today) else {
            return currentMonthTarget
        }
        return clamped(previousMonth, day: targetDay)
    }

    /// After a restore or a failed scheduled run, pretend this slot already happened so the
    /// daemon does not fire immediately (`suppress_immediate_auto_backup`).
    public static func suppressImmediateAutoBackup(
        _ configuration: inout FaugusConfig,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) {
        if configuration.values["backup-last-auto-date"] != nil || configuration.bool("backup-auto-enabled") {
            configuration.setRaw(
                "backup-last-auto-date",
                .string(BackupFormat.lastBackupStamp(now: now, timeZone: timeZone))
            )
        }
    }

    public static func parseLastBackup(_ text: String, timeZone: TimeZone = .current) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }
}
