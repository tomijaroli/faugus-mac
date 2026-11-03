import Darwin
import FaugusCore
import Foundation

/// Upstream's tray process is the single owner of the launcher: starting `faugus-launcher` again just
/// asks it to open its window (`Open` over D-Bus). Here a second launcher process posts the `open`
/// notification to the running one and exits.
///
/// Helpers (`--game`, `--run`, `--daemon`, `--shortcut`) share this bundle id but have no launcher
/// window and ignore `faugusOpen`. Matching `NSRunningApplication` would hand over to them and the
/// new GUI would exit — Faugus looks like it never started. Only the process that holds
/// `launcher.lock` is treated as the GUI.
enum SingleInstance {
    /// Held for the lifetime of the GUI so the kernel drops the lock if this process dies.
    /// Touched only from the main entry before the event loop; the kernel flock is the real guard.
    private static nonisolated(unsafe) var lockFileDescriptor: Int32 = -1

    /// Returns `true` when another launcher is already running and was asked to present itself.
    ///
    /// Pass `claimLock: false` from `--shortcut` so the shortcut window does not become the GUI owner.
    static func handOverToRunningInstance(
        file: String? = nil,
        shortcut: String? = nil,
        claimLock: Bool = true
    ) -> Bool {
        // A custom home (QA runs, tests) is an independent launcher.
        guard ProcessInfo.processInfo.environment["FAUGUS_HOME"] == nil else { return false }
        if claimLock {
            if claimLauncherLock() { return false }
        } else if !isLauncherLockHeld() {
            return false
        }
        notifyRunningLauncher(file: file, shortcut: shortcut)
        // Give distnoted a moment to deliver before this process exits. If the other GUI died
        // in between, take the lock and start anyway.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        if claimLock, claimLauncherLock() {
            return false
        }
        return true
    }

    private static func notifyRunningLauncher(file: String?, shortcut: String?) {
        var userInfo: [String: String] = [:]
        if let file {
            userInfo["file"] = file
        }
        if let shortcut {
            userInfo["shortcut"] = shortcut
        }
        DistributedNotificationCenter.default().postNotificationName(
            .faugusOpen, object: nil, userInfo: userInfo.isEmpty ? nil : userInfo, deliverImmediately: true
        )
    }

    private static func claimLauncherLock() -> Bool {
        if lockFileDescriptor >= 0 { return true }
        let paths = FaugusPaths.live
        try? FileManager.default.createDirectory(atPath: paths.stateDirectory, withIntermediateDirectories: true)
        let fileDescriptor = open(paths.launcherLockFile, O_CREAT | O_RDWR, 0o644)
        guard fileDescriptor >= 0 else { return true }
        if flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 {
            lockFileDescriptor = fileDescriptor
            return true
        }
        close(fileDescriptor)
        return false
    }

    private static func isLauncherLockHeld() -> Bool {
        let fileDescriptor = open(FaugusPaths.live.launcherLockFile, O_RDONLY)
        guard fileDescriptor >= 0 else { return false }
        defer { close(fileDescriptor) }
        if flock(fileDescriptor, LOCK_EX | LOCK_NB) != 0 {
            return errno == EWOULDBLOCK
        }
        _ = flock(fileDescriptor, LOCK_UN)
        return false
    }
}
