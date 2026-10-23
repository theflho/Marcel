import UIKit
import UserNotifications

/// Shows Marcel's notifications even while the app is open, and answers a clock-in reminder:
/// "Oui" sends RMA's text (through the user's Shortcut, or Messages with it ready), "Non" does
/// nothing, a tap or "Ouvrir le portail" opens the portal.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let isStart = info["start"] as? Bool ?? true
        let portal = info["url"] as? String
        await MainActor.run {
            switch action {
            case WorkReminders.yesAction:
                if let url = WorkReminders.sendURL(start: isStart) { UIApplication.shared.open(url) }
            case WorkReminders.noAction:
                break
            default:
                if let portal, let url = URL(string: portal) { UIApplication.shared.open(url) }
            }
        }
    }
}
