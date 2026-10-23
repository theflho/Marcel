import Foundation
import UserNotifications

/// Reminders 5 minutes before each start and end of a work mission (RMA planning read on the
/// server). The iPhone schedules them itself, so they arrive on time even with the app closed.
/// They only remind: a tap opens the portal, and clocking in stays the user's own act, on site.
enum WorkReminders {
    static let enabledKey = "workReminders"
    static let portalURL = "https://ecollaborateurs.rmasa.com/#/accueil/missions"
    private static let scheduledKey = "workReminderIDs"
    private static let lead: TimeInterval = 5 * 60
    // iOS keeps at most 64 pending notifications per app; room is left for the others.
    private static let maxPending = 50

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Turns the reminders on (asking iOS first) or off. Returns whether they are on.
    static func setEnabled(_ enabled: Bool) async -> Bool {
        guard enabled else {
            UserDefaults.standard.set(false, forKey: enabledKey)
            clear()
            return false
        }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        UserDefaults.standard.set(granted, forKey: enabledKey)
        return granted
    }

    /// Replaces the scheduled reminders with the current planning.
    static func schedule(_ missions: [PlanningMission]) async {
        clear()
        guard isEnabled else { return }
        var ids: [String] = []
        for mission in missions.sorted(by: { $0.startAt < $1.startAt }) {
            for (moment, isStart) in [(mission.startAt, true), (mission.endAt, false)] {
                let fire = moment.addingTimeInterval(-lead)
                guard fire > .now, ids.count < maxPending else { continue }
                let content = UNMutableNotificationContent()
                content.title = isStart ? "Pointage de début dans 5 min" : "Pointage de fin dans 5 min"
                content.body = "\(mission.store) · \(isStart ? "début" : "fin") à \(moment.formatted(date: .omitted, time: .shortened)). "
                    + "Touche pour ouvrir le portail et pointer sur place."
                content.sound = .default
                content.userInfo = ["url": portalURL]
                let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                let id = "rma-\(mission.id)-\(isStart ? "debut" : "fin")"
                let request = UNNotificationRequest(identifier: id, content: content,
                                                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
                try? await UNUserNotificationCenter.current().add(request)
                ids.append(id)
            }
        }
        UserDefaults.standard.set(ids, forKey: scheduledKey)
    }

    static func clear() {
        let ids = UserDefaults.standard.stringArray(forKey: scheduledKey) ?? []
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        UserDefaults.standard.removeObject(forKey: scheduledKey)
    }
}
