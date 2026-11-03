@testable import FaugusCore
import Foundation
import Testing

@Suite("backup")
struct BackupFormatTests {
    @Test func formatSizeMatchesUpstream() {
        #expect(BackupFormat.formatSize(0) == "0 B")
        #expect(BackupFormat.formatSize(512) == "512 B")
        #expect(BackupFormat.formatSize(1024) == "1.00 KB")
        #expect(BackupFormat.formatSize(1_572_864) == "1.50 MB")
    }

    @Test func uniqueArchivePathAddsNumericSuffix() {
        let existing = Set([
            "/backups/faugus-launcher-2026-03-10_00-00-00.tar",
            "/backups/faugus-launcher-2026-03-10_00-00-00-2.tar",
        ])
        let path = BackupFormat.uniqueArchivePath(
            in: "/backups",
            fileName: "faugus-launcher-2026-03-10_00-00-00.tar",
            fileExists: { existing.contains($0) }
        )
        #expect(path == "/backups/faugus-launcher-2026-03-10_00-00-00-3.tar")
    }

    @Test func archiveFileNameUsesTimestamp() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 4, minute: 5, second: 6))!
        #expect(
            BackupFormat.archiveFileName(now: now, timeZone: calendar.timeZone)
                == "faugus-launcher-2026-03-10_04-05-06.tar"
        )
        #expect(BackupFormat.lastBackupStamp(now: now, timeZone: calendar.timeZone) == "2026-03-10 04:05")
    }
}

@Suite("backup schedule")
struct BackupScheduleTests {
    private func configuration(paths: FaugusPaths) throws -> FaugusConfig {
        try FaugusConfig.load(paths: paths, language: "en_US")
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func disabledNeverRuns() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        var configuration = try configuration(paths: paths)
        configuration.setValue("backup-auto-enabled", bool: false)
        #expect(!BackupSchedule.shouldRun(configuration: configuration, now: date(2026, 3, 10, 1), calendar: utc))
    }

    @Test func dailyRunsAfterMidnightWhenLastBackupWasYesterday() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        var configuration = try configuration(paths: paths)
        configuration.setValue("backup-auto-enabled", bool: true)
        configuration.setValue("backup-frequency", "daily")
        configuration.setRaw("backup-target-time", "00:00")
        configuration.setRaw("backup-last-auto-date", "2026-03-09 12:00")
        #expect(BackupSchedule.shouldRun(configuration: configuration, now: date(2026, 3, 10, 0, 1), calendar: utc))
    }

    @Test func dailyDoesNotRerunTheSameDay() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        var configuration = try configuration(paths: paths)
        configuration.setValue("backup-auto-enabled", bool: true)
        configuration.setValue("backup-frequency", "daily")
        configuration.setRaw("backup-target-time", "00:00")
        configuration.setRaw("backup-last-auto-date", "2026-03-10 00:30")
        #expect(!BackupSchedule.shouldRun(configuration: configuration, now: date(2026, 3, 10, 12), calendar: utc))
    }

    @Test func weeklyUsesMondayEqualsZero() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        var configuration = try configuration(paths: paths)
        configuration.setValue("backup-auto-enabled", bool: true)
        configuration.setValue("backup-frequency", "weekly")
        configuration.setValue("backup-target-day", "1") // Tuesday
        configuration.setRaw("backup-target-time", "00:00")
        configuration.setRaw("backup-last-auto-date", "2026-03-03 00:00")
        // 2026-03-10 is a Tuesday.
        #expect(BackupSchedule.shouldRun(configuration: configuration, now: date(2026, 3, 10, 1), calendar: utc))
        #expect(BackupSchedule.pythonWeekday(date(2026, 3, 9), calendar: utc) == 0)
        #expect(BackupSchedule.pythonWeekday(date(2026, 3, 10), calendar: utc) == 1)
    }

    @Test func monthlyClampsDayThirtyOneInFebruary() {
        let today = date(2026, 2, 10)
        let target = BackupSchedule.lastMonthlyTarget(today: utc.startOfDay(for: today), targetDay: 31, calendar: utc)
        let components = utc.dateComponents([.year, .month, .day], from: target)
        #expect(components.year == 2026)
        #expect(components.month == 1)
        #expect(components.day == 31)
    }
}

@Suite("backup selection")
struct BackupSelectionTests {
    @Test func resolveExcludedIDsInvertsLegacyIncludedList() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        var configuration = try FaugusConfig.load(paths: paths, language: "en_US")
        configuration.setRaw("backup-prefix-ids", .array(["keep"]))
        let excluded = BackupInventory.resolveExcludedIDs(
            configuration: configuration,
            excludedKey: "backup-excluded-prefix-ids",
            includedKey: "backup-prefix-ids",
            allIDs: ["keep", "drop"]
        )
        #expect(excluded == ["drop"])
    }

    @Test func steamGamesAreOmittedAndDefaultPrefixIsFirst() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        try FileManager.default.createDirectory(atPath: paths.defaultPrefix, withIntermediateDirectories: true)
        var configuration = try FaugusConfig.load(paths: paths, language: "en_US")
        configuration.setValue("default-prefix", paths.prefixesDirectory)
        var windows = Game(gameID: "game-a", title: "Alpha")
        windows.prefix = paths.prefixesDirectory + "/game-a"
        var steam = Game(gameID: "steam-1", title: "Steam Game")
        steam.runner = "Steam"
        steam.prefix = paths.prefixesDirectory + "/steam-1"
        let items = BackupInventory.prefixItems(paths: paths, configuration: configuration, games: [windows, steam])
        #expect(items.map(\.gameID) == ["default", "game-a"])
    }
}

@Suite("backup session")
struct BackupSessionTests {
    @Test func roundTripRestoresSettingsPrefixAndSkipsDesktopShortcuts() async throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        try paths.ensureDirectories()
        try FileManager.default.createDirectory(atPath: paths.coversDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: paths.prefixesDirectory, withIntermediateDirectories: true)

        var configuration = try FaugusConfig.load(paths: paths, language: "en_US")
        configuration.setValue("backup-dest-dir", paths.home + "/Faugus Backup")
        try configuration.save()

        var game = Game(gameID: "celeste", title: "Celeste")
        game.path = paths.prefixesDirectory + "/celeste/drive_c/game.exe"
        game.prefix = paths.prefixesDirectory + "/celeste"
        game.cover = paths.coversDirectory + "/celeste.png"
        try GamesStore(paths: paths).save(games: [game])
        try Data("cover".utf8).write(to: URL(fileURLWithPath: paths.coversDirectory + "/celeste.png"))
        try Data("other".utf8).write(to: URL(fileURLWithPath: paths.coversDirectory + "/other.png"))

        let prefixPath = paths.prefixesDirectory + "/celeste"
        try FileManager.default.createDirectory(
            atPath: prefixPath + "/drive_c/users/steamuser", withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: prefixPath + "/dosdevices", withIntermediateDirectories: true
        )
        try Data("save".utf8).write(
            to: URL(fileURLWithPath: prefixPath + "/drive_c/users/steamuser/save.dat")
        )
        try FileManager.default.createSymbolicLink(
            atPath: prefixPath + "/dosdevices/dangling", withDestinationPath: "/no/such/target"
        )

        let backupDirectory = paths.home + "/Faugus Backup"
        try FileManager.default.createDirectory(atPath: backupDirectory, withIntermediateDirectories: true)
        let destination = backupDirectory + "/faugus-launcher-test.tar"
        let selection = BackupSelection(
            gameIDs: ["celeste"],
            prefixes: [
                BackupPrefixItem(gameID: "celeste", title: "Celeste", path: prefixPath, hasPrefix: true)
            ],
            shortcuts: [
                BackupPrefixItem(
                    gameID: "celeste", title: "Celeste", path: prefixPath, hasPrefix: true,
                    shortcutFiles: ["/home/linux/Desktop/celeste.desktop"]
                )
            ]
        )
        let stamp = try await BackupSession(paths: paths).perform(
            destinationPath: destination, selection: selection, games: [game]
        )
        #expect(!stamp.isEmpty)
        #expect(FileManager.default.fileExists(atPath: destination))

        try FileManager.default.removeItem(atPath: paths.coversDirectory + "/celeste.png")
        try FileManager.default.removeItem(atPath: prefixPath)

        let preview = try await BackupRestore(paths: paths).preview(archivePath: destination)
        #expect(preview.manifest?.version == 2)
        #expect(preview.prefixItems.map(\.gameID) == ["celeste"])
        #expect(BackupArchive.isFaugusBackup(stagingDirectory: preview.stagingDirectory))

        let outcome = try BackupRestore(paths: paths).restore(
            preview: preview,
            selectedGameIDs: ["celeste"],
            selectedPrefixes: preview.prefixItems,
            selectedShortcuts: preview.prefixItems,
            selectedRunners: [],
            macUserName: "tomi"
        )
        #expect(FileManager.default.fileExists(atPath: paths.coversDirectory + "/celeste.png"))
        #expect(!FileManager.default.fileExists(atPath: paths.coversDirectory + "/other.png"))
        #expect(FileManager.default.fileExists(atPath: prefixPath + "/drive_c/users/tomi/save.dat"))
        #expect(
            try (FileManager.default.destinationOfSymbolicLink(atPath: prefixPath + "/drive_c/users/steamuser"))
                == "tomi"
        )
        #expect(!FileManager.default.fileExists(atPath: prefixPath + "/dosdevices/dangling"))
        #expect(!FileManager.default.fileExists(atPath: "/home/linux/Desktop/celeste.desktop"))
        #expect(outcome.importedLinux)
    }

    @Test func cancelFileAborts() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        try paths.ensureDirectories()
        BackupLock.requestCancel(paths: paths)
        #expect(throws: BackupError.cancelled) {
            try BackupLock.throwIfCancelled(paths: paths)
        }
    }

    @Test func unsafeMembersAreRejected() throws {
        #expect(throws: RunnerError.unsafeArchive("../secret")) {
            try ArchiveSafety.validate(memberNames: ["../secret"])
        }
        #expect(throws: RunnerError.unsafeArchive("/etc/passwd")) {
            try ArchiveSafety.validate(memberNames: ["/etc/passwd"])
        }
    }
}

@Suite("linux import")
struct LinuxFixupTests {
    @Test func rewritesHomeFaugusAndXDGPaths() {
        let paths = FaugusPaths(home: "/Users/tomi")
        #expect(
            LinuxFixup.rewriteLinuxPath("/home/alice/Faugus/celeste/drive_c/game.exe", paths: paths)
                == "/Users/tomi/Faugus/celeste/drive_c/game.exe"
        )
        #expect(
            LinuxFixup.rewriteLinuxPath("/home/alice/.config/faugus-launcher/config.json", paths: paths)
                == "/Users/tomi/Library/Application Support/Faugus/config/config.json"
        )
        #expect(
            LinuxFixup.rewriteLinuxPath("/home/alice/.local/share/faugus-launcher/games.json", paths: paths)
                == "/Users/tomi/Library/Application Support/Faugus/data/games.json"
        )
        #expect(LinuxFixup.rewriteLinuxPath("/opt/games/foo", paths: paths) == "/opt/games/foo")
    }

    @Test func mapsProtonAndMarksLinuxNative() throws {
        let paths = try TestSupport.makeTemporaryHome()
        defer { TestSupport.cleanup(paths) }
        try paths.ensureDirectories()
        var proton = Game(gameID: "win-game", title: "Win")
        proton.runner = "Proton-CachyOS Latest"
        proton.path = "/home/alice/Faugus/win-game/drive_c/game.exe"
        proton.prefix = "/home/alice/Faugus/win-game"
        var native = Game(gameID: "native", title: "Native")
        native.runner = "Linux-Native"
        native.path = "/usr/bin/native"
        try GamesStore(paths: paths).save(games: [proton, native])

        let outcome = try LinuxFixup.apply(paths: paths, macUserName: "tomi")
        let games = try GamesStore(paths: paths).loadAll()
        let win = games.first { $0.gameID == "win-game" }!
        let linux = games.first { $0.gameID == "native" }!
        #expect(win.runner == "Default")
        #expect(win.path.hasPrefix(paths.prefixesDirectory))
        #expect(win.needsAttention)
        #expect(linux.needsAttention)
        #expect(linux.runner == "Linux-Native")
        #expect(outcome.importedLinux)
    }

    @Test func protonRunnerDetection() {
        #expect(LinuxFixup.isProtonRunner("Proton-CachyOS Latest"))
        #expect(LinuxFixup.isProtonRunner("GE-Proton9-20"))
        #expect(LinuxFixup.isProtonRunner("umu-proton"))
        #expect(!LinuxFixup.isProtonRunner("Wine-Staging-11.21"))
        #expect(LinuxFixup.isLinuxOnlyRunner("Linux-Native"))
        #expect(LinuxFixup.isLinuxOnlyRunner("Steam-Linux"))
        #expect(!LinuxFixup.isLinuxOnlyRunner("Steam"))
    }

    @Test func needsAttentionClearsWhenSetFalse() {
        var game = Game(gameID: "x", title: "X")
        game.needsAttention = true
        #expect(game.saveObject()["mac-needs-attention"] == .bool(true))
        game.needsAttention = false
        #expect(game.saveObject()["mac-needs-attention"] == nil)
    }
}
