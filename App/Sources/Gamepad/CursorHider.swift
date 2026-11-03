import AppKit
import Foundation

/// Hides the pointer while a gamepad is in use, then shows it again on mouse or keyboard.
/// A 0.5 s grace (`CURSOR_GRACE`) ignores the first motion after hiding.
@MainActor
final class CursorHider {
    static let grace: TimeInterval = 0.5

    private var isHidden = false
    private var graceUntil: TimeInterval = 0
    private var mouseMonitor: Any?
    private var keyMonitor: Any?

    func start() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .mouseMoved,
            .leftMouseDragged,
        ]) { [weak self] event in
            self?.pointerMoved()
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.show()
            return event
        }
    }

    func stop() {
        show()
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        mouseMonitor = nil
        keyMonitor = nil
    }

    func hide() {
        if !isHidden {
            NSCursor.hide()
            isHidden = true
            graceUntil = ProcessInfo.processInfo.systemUptime + Self.grace
        }
    }

    func show() {
        guard isHidden else { return }
        NSCursor.unhide()
        isHidden = false
    }

    private func pointerMoved() {
        guard isHidden, ProcessInfo.processInfo.systemUptime >= graceUntil else { return }
        show()
    }
}
