import Foundation
import UserNotifications

/// Reminders 5 minutes before each start and end of a work mission (RMA planning read on the
/// server). The iPhone schedules them itself, so they arrive on time even with the app closed.
/// Each one prepares RMA's text-message clock-in ("RMA OK" to start, "RMA fin" to leave, to
/// 38200) and asks "J'envoie ?": nothing is sent without the user's "Oui", given each time.
/// iOS lets no app send a text by itself: "Oui" runs the user's Shortcut « Pointer RMA »
/// (sends without another screen), or, without it, opens Messages with the text ready.
enum WorkReminders {
    static let enabledKey = "workReminders"
    static let portalURL = "https://ecollaborateurs.rmasa.com/#/accueil/missions"
    /// RMA's clock-in by text message: reply "RMA OK" when starting, "RMA fin" when leaving.
    static let smsNumber = "38200"
    static let category = "rma-clock"
    static let yesAction = "send"
    static let noAction = "skip"
    static let portalAction = "portal"
    /// The user made the Shortcut « Pointer RMA » (Settings › Sur cet iPhone).
    static let shortcutKey = "clockShortcut"
    static let shortcutName = "Pointer RMA"

    /// The reminders' buttons; registered once, at launch.
    static func registerActions() {
        let yes = UNNotificationAction(identifier: yesAction, title: "Oui, envoyer", options: [.foreground])
        let no = UNNotificationAction(identifier: noAction, title: "Non", options: [])
        let portal = UNNotificationAction(identifier: portalAction, title: "Ouvrir le portail", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [yes, no, portal], intentIdentifiers: []),
        ])
    }

    static func message(start: Bool) -> String { start ? "RMA OK" : "RMA fin" }

    /// What "Oui" opens: the Shortcut that sends the text, or Messages with it ready.
    static func sendURL(start: Bool) -> URL? {
        let text = message(start: start).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if UserDefaults.standard.bool(forKey: shortcutKey) {
            let name = shortcutName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            return URL(string: "shortcuts://run-shortcut?name=\(name)&input=text&text=\(text)")
        }
        return URL(string: "sms:\(smsNumber)&body=\(text)")
    }

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
                content.title = "Pointage de \(isStart ? "début" : "fin") · \(mission.store)"
                content.body = "\(isStart ? "Début" : "Fin") à \(moment.formatted(date: .omitted, time: .shortened)). "
                    + "Je prépare « \(message(start: isStart)) » pour le \(smsNumber). J'envoie ? (une fois sur place)"
                content.sound = .default
                content.categoryIdentifier = category
                content.userInfo = ["url": portalURL, "start": isStart]
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
