import BackgroundTasks
import UserNotifications

/// While the app is closed, iOS wakes it from time to time (it decides when, often about once an
/// hour or less): Marcel then looks for new ideas and replies that finished, and shows a local
/// notification. No push server or paid Apple account is involved.
enum BackgroundRefresh {
    static let identifier = "com.theobrosselin.marcel.refresh"
    static let enabledKey = "localNotifications"
    private static let notifiedKey = "notifiedItems"
    private static let emergencyKey = "emergencyStop"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Turns notifications on (asking iOS first) or off. Returns whether they are on.
    static func setEnabled(_ enabled: Bool) async -> Bool {
        guard enabled else {
            UserDefaults.standard.set(false, forKey: enabledKey)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            return false
        }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        UserDefaults.standard.set(granted, forKey: enabledKey)
        if granted { schedule() }
        return granted
    }

    /// Asks iOS for the next wake-up; called each time the app goes to the background.
    static func schedule() {
        guard isEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = .now.addingTimeInterval(20 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// One background wake-up: new ideas and finished replies on the active server.
    static func run() async {
        schedule()
        guard isEnabled, !UserDefaults.standard.bool(forKey: emergencyKey) else { return }
        let settings = ServerSettings()
        guard let api = settings.api else { return }
        var notified = Set(UserDefaults.standard.stringArray(forKey: notifiedKey) ?? [])

        if let ideas = try? await api.ideas() {
            for idea in ideas.filter({ $0.status == "new" && !notified.contains("idea-\($0.id)") }).prefix(3) {
                await post(id: "idea-\(idea.id)", title: "Marcel a une idée", body: idea.title)
                notified.insert("idea-\(idea.id)")
            }
        }

        let waiting = ConversationCache().loadAll().compactMap { conversation -> (String, String)? in
            guard let reply = conversation.messages.last, reply.status == .streaming,
                  reply.serverID == nil || reply.serverID == settings.activeID,
                  let missionID = reply.missionID, !notified.contains("mission-\(missionID)") else { return nil }
            return (missionID, conversation.title)
        }
        for (missionID, title) in waiting.prefix(5) {
            guard let mission = try? await api.mission(id: missionID), mission.status != "running" else { continue }
            let body = mission.status == "done" ? title : "\(title) : la réponse n'a pas pu aboutir."
            await post(id: "mission-\(missionID)", title: "Marcel a répondu", body: body)
            notified.insert("mission-\(missionID)")
        }

        // Keep the list short: only recent ids can come back.
        UserDefaults.standard.set(Array(notified.suffix(100)), forKey: notifiedKey)
    }

    private static func post(id: String, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
