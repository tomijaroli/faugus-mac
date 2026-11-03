import CoreGraphics
import FaugusCore
import Foundation

/// Detects the game's first real window so the splash can close (upstream closes its splash
/// when the game window shows). Only window owner PIDs and bounds are read, which needs no
/// Screen Recording permission.
enum GameWindowWatcher {
    /// `true` when any on-screen, normal-layer window of at least 200x150 belongs to a process
    /// tagged `FAUGUSID=<gameID>`.
    static func gameWindowVisible(gameID: String) -> Bool {
        let tagged = Set(ProcessScanner.pids(withEnvironment: "FAUGUSID", equalTo: gameID))
        guard !tagged.isEmpty else { return false }
        guard
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return false }
        for w in info {
            guard let owner = w[kCGWindowOwnerPID as String] as? Int32, tagged.contains(owner),
                (w[kCGWindowLayer as String] as? Int) == 0,
                let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            if bounds.width >= 200, bounds.height >= 150 { return true }
        }
        return false
    }
}
