import UIKit
import UserNotifications

/// Shows Marcel's notifications even while the app is open, and opens what a clock-in reminder
/// offers: the portal (tap or button), or Messages with RMA's reply already typed (button).
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let key = response.actionIdentifier == WorkReminders.smsAction ? "sms" : "url"
        guard let link = info[key] as? String, let url = URL(string: link) else { return }
        await MainActor.run { UIApplication.shared.open(url) }
    }
}
