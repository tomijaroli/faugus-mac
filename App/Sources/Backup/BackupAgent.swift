import FaugusCore
import Foundation
import ServiceManagement

/// `setup_autostart` for the backup daemon: an `SMAppService` LaunchAgent that runs
/// `Faugus --daemon --once` every 60 seconds.
enum BackupAgent {
    static let plistName = "me.tomijaroli.faugus-mac.backup.plist"

    static func apply(enabled: Bool) throws {
        let service = SMAppService.agent(plistName: plistName)
        if enabled {
            if service.status != .enabled {
                try service.register()
            }
        } else if service.status == .enabled {
            try service.unregister()
        }
    }
}
