import Foundation
import UserNotifications

/// Desktop notifications for backup start/finish/cancel/failure (`send_desktop_notification`).
enum BackupNotifications {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func send(body: String, title: String = "Faugus") {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: "faugus-backup-" + UUID().uuidString.lowercased(),
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
