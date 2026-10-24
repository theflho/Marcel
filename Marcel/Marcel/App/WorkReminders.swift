import Foundation
import UserNotifications

/// Reminders a few minutes (5 by default, set with the Pointage assistant) before each start
/// and end of a work mission (RMA planning read on the server). The iPhone schedules them itself, so they arrive on time even with the app closed.
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

    // The Pointage assistant's settings (set in its conversation), kept on the iPhone so the
    // reminders follow them even without a connection.
    private static let leadKey = "pointageLead"
    private static let startKey = "pointageStart"
    private static let endKey = "pointageEnd"
    private static let startTextKey = "pointageStartText"
    private static let endTextKey = "pointageEndText"

    static func message(start: Bool) -> String {
        let text = UserDefaults.standard.string(forKey: start ? startTextKey : endTextKey) ?? ""
        return text.isEmpty ? (start ? "RMA OK" : "RMA fin") : text
    }

    private static var lead: TimeInterval {
        let minutes = UserDefaults.standard.integer(forKey: leadKey)
        return TimeInterval((1...30).contains(minutes) ? minutes : 5) * 60
    }

    private static func wanted(start: Bool) -> Bool {
        UserDefaults.standard.object(forKey: start ? startKey : endKey) as? Bool ?? true
    }

    /// Keeps Pointage's settings; returns whether they changed (the reminders are then rescheduled).
    static func apply(_ pointage: Assistant) -> Bool {
        let defaults = UserDefaults.standard
        let before = [defaults.object(forKey: leadKey), defaults.object(forKey: startKey), defaults.object(forKey: endKey),
                      defaults.object(forKey: startTextKey), defaults.object(forKey: endTextKey)].map { String(describing: $0) }
        for (key, setting) in [(leadKey, "lead_minutes"), (startKey, "start_reminder"), (endKey, "end_reminder"),
                               (startTextKey, "start_text"), (endTextKey, "end_text")] {
            switch pointage.setting(setting)?.value {
            case .int(let value)?: defaults.set(value, forKey: key)
            case .bool(let value)?: defaults.set(value, forKey: key)
            case .text(let value)?: defaults.set(value, forKey: key)
            case nil: break
            }
        }
        let after = [defaults.object(forKey: leadKey), defaults.object(forKey: startKey), defaults.object(forKey: endKey),
                     defaults.object(forKey: startTextKey), defaults.object(forKey: endTextKey)].map { String(describing: $0) }
        return before != after
    }

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
            for (moment, isStart) in [(mission.startAt, true), (mission.endAt, false)] where wanted(start: isStart) {
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
