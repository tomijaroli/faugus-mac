import AppKit
import ApplicationServices
import Foundation

/// Power menu: Shut down / Reboot via Apple Events to loginwindow; Close quits Faugus
/// (`on_shutdown` / `on_reboot` / `on_close_fullscreen`).
@MainActor
enum PowerAction {
    private static let shutDownEvent = AEEventID(0x7368_7574) // 'shut'
    private static let restartEvent = AEEventID(0x7265_7374) // 'rest'

    static func shutDown() {
        send(shutDownEvent)
    }

    static func reboot() {
        send(restartEvent)
    }

    static func closeLauncher() {
        NSApp.terminate(nil)
    }

    private static func send(_ eventID: AEEventID) {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow")
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: eventID,
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        do {
            try event.sendEvent(options: .noReply, timeout: 5)
        } catch {
            FileHandle.standardError.write(
                Data("Faugus: power menu Apple Event failed: \(error.localizedDescription)\n".utf8)
            )
        }
    }
}
