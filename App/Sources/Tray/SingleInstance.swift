import AppKit
import Foundation

/// Upstream's tray process is the single owner of the launcher: starting `faugus-launcher` again just
/// asks it to open its window (`Open` over D-Bus). Here a second launcher process posts the `open`
/// notification to the running one and exits.
enum SingleInstance {
    /// Returns `true` when another launcher is already running and was asked to present itself.
    static func handOverToRunningInstance(file: String?) -> Bool {
        // A custom home (QA runs, tests) is an independent launcher.
        guard ProcessInfo.processInfo.environment["FAUGUS_HOME"] == nil,
              let bundleIdentifier = Bundle.main.bundleIdentifier
        else { return false }
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != ownProcessIdentifier && !$0.isTerminated }
        guard !otherInstances.isEmpty else { return false }
        DistributedNotificationCenter.default().postNotificationName(
            .faugusOpen, object: nil, userInfo: file.map { ["file": $0] }, deliverImmediately: true
        )
        // Give distnoted a moment to deliver before this process exits.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        return true
    }
}
