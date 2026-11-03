import CoreGraphics
import FaugusCore
import Foundation

/// Detects the game's first real window so the splash can close (upstream closes its splash
/// when the game window shows). Only window owner PIDs and bounds are read, which needs no
/// Screen Recording permission.
enum GameWindowWatcher {
    /// `true` when any on-screen, normal-layer window of at least 200x150 belongs to a process
    /// tagged `FAUGUSID=<gameID>`, or (Wine) `WINEPREFIX=<prefix>`.
    ///
    /// Battle.net's `Launcher.exe` exits immediately and the real `Battle.net.exe` is spawned by
    /// wineserver, which strips `FAUGUSID` from the environment. Matching the prefix is what lets
    /// the splash close for that class of launcher.
    static func gameWindowVisible(gameID: String, prefix: String? = nil) -> Bool {
        var tagged = Set(ProcessScanner.pids(withEnvironment: "FAUGUSID", equalTo: gameID))
        if let prefix, !prefix.isEmpty {
            tagged.formUnion(ProcessScanner.pids(withEnvironment: "WINEPREFIX", equalTo: prefix))
        }
        guard !tagged.isEmpty else { return false }
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return false }
        for window in info {
            guard let owner = window[kCGWindowOwnerPID as String] as? Int32, tagged.contains(owner),
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            if bounds.width >= 200, bounds.height >= 150 {
                return true
            }
        }
        return false
    }
}
