import AppKit
import FaugusCore
import Foundation

/// `faugus.backup_daemon --daemon [--once]`.
enum DaemonMode {
    static func run(once: Bool) -> Never {
        BackupNotifications.requestAuthorization()
        if once {
            Task {
                await runScheduledBackup()
                exit(0)
            }
            RunLoop.main.run()
            exit(0)
        }

        let paths = FaugusPaths.live
        try? FileManager.default.createDirectory(atPath: paths.stateDirectory, withIntermediateDirectories: true)
        let token = "\(ProcessInfo.processInfo.processIdentifier)-\(Date().timeIntervalSince1970)"
        try? token.write(toFile: paths.backupDaemonTokenFile, atomically: true, encoding: .utf8)

        var lastCheck: TimeInterval = 0
        while true {
            let current = (try? String(contentsOfFile: paths.backupDaemonTokenFile, encoding: .utf8))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? token
            if current != token {
                exit(0)
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastCheck >= 60 {
                lastCheck = now
                let finished = DispatchSemaphore(value: 0)
                Task {
                    await runScheduledBackup()
                    finished.signal()
                }
                finished.wait()
            }
            Thread.sleep(forTimeInterval: 5)
        }
    }

    static func runScheduledBackup() async {
        let paths = FaugusPaths.live
        var configuration: FaugusConfig
        do {
            configuration = try FaugusConfig.load(paths: paths)
        } catch {
            BackupNotifications.send(body: "Backup failed.")
            return
        }
        guard BackupSchedule.shouldRun(configuration: configuration) else { return }

        let destinationDirectory = configuration.string("backup-dest-dir").isEmpty
            ? paths.home : paths.expand(configuration.string("backup-dest-dir"))
        let games = (try? GamesStore(paths: paths).loadAll()) ?? []
        let items = BackupInventory.prefixItemsWithShortcuts(
            paths: paths,
            configuration: configuration,
            games: games,
            executablePath: Bundle.main.executablePath ?? CommandLine.arguments[0],
            fallbackIconPath: ""
        )
        let runners = BackupInventory.runnerItems(paths: paths)
        let selection = BackupInventory.selection(from: configuration, items: items, runners: runners)
        let needed = BackupInventory.estimateSize(paths: paths, selection: selection)
        if let available = BackupCopy.freeSpace(at: destinationDirectory), needed > available {
            BackupNotifications.send(
                body: "Backup failed: not enough disk space (\(BackupFormat.formatSize(needed)) needed, \(BackupFormat.formatSize(available)) available)."
            )
            BackupSchedule.suppressImmediateAutoBackup(&configuration)
            try? configuration.save()
            return
        }

        BackupNotifications.send(body: "Backup started")
        do {
            let destination = BackupFormat.uniqueArchivePath(in: destinationDirectory)
            let stamp = try await BackupSession(paths: paths).perform(
                destinationPath: destination, selection: selection, games: games
            )
            configuration.setValue("backup-last-date", stamp)
            configuration.setRaw("backup-last-auto-date", .string(stamp))
            try configuration.save()
            BackupNotifications.send(body: "Backup completed")
        } catch BackupError.cancelled {
            BackupNotifications.send(body: "Backup cancelled")
            BackupSchedule.suppressImmediateAutoBackup(&configuration)
            try? configuration.save()
        } catch {
            BackupNotifications.send(body: "Backup failed.")
            BackupSchedule.suppressImmediateAutoBackup(&configuration)
            try? configuration.save()
        }
    }
}
