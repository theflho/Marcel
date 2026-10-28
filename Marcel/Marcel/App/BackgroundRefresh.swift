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
    private static let codeLogSeenKey = "codeLogSeen"

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

        // Routines that ran: their reply is put in their conversation when the app opens.
        if let runs = try? await api.pendingRoutineRuns() {
            for run in runs.filter({ !notified.contains("routine-\($0.id)") }).prefix(3) {
                notified.insert("routine-\(run.id)")
                // Its bot's Notifications switch is off (its card).
                if let bot = run.assistant, !bot.isEmpty, !BotPrefs.notifies(bot) { continue }
                if run.status == "done", (run.actions ?? []).contains(where: \.awaitsApproval)
                    || (run.text ?? "").contains("```reglage") && !(run.actions ?? []).contains(where: { $0.id.hasPrefix("auto-reglage") || $0.id.hasPrefix("auto-off-reglage") }) {
                    let name = run.assistantName.flatMap { $0.isEmpty ? nil : $0 } ?? "Marcel"
                    await post(id: "routine-\(run.id)", title: "\(name) attend ton accord",
                               body: run.title ?? "Une action attend « Autoriser » dans sa conversation.")
                    continue
                }
                let firstLine = (run.text ?? "").split(separator: "\n").first.map(String.init) ?? ""
                // An assistant's relance comes from it, like a message.
                let title = run.assistantName.flatMap { $0.isEmpty ? nil : $0 } ?? "Routine · \(run.title ?? "Marcel")"
                await post(id: "routine-\(run.id)", title: title,
                           body: run.status == "done" ? AutoBlocks.strip(firstLine).replacingOccurrences(of: "**", with: "")
                                                      : "La routine n'a pas pu aboutir.")
            }
        }

        // What Hermes sent on its own (a cron job's result), like a Telegram message.
        if let entries = try? await api.pendingBotMessages() {
            for entry in entries.filter({ $0.question.isEmpty && !notified.contains("hermes-\($0.id)") }).prefix(3) {
                notified.insert("hermes-\(entry.id)")
                if !entry.assistant.isEmpty, !BotPrefs.notifies(entry.assistant) { continue }
                let firstLine = entry.text.split(separator: "\n").first.map(String.init) ?? ""
                await post(id: "hermes-\(entry.id)", title: entry.assistantName,
                           body: AutoBlocks.strip(firstLine).replacingOccurrences(of: "**", with: ""))
            }
        }

        let waiting = ConversationCache().loadAll().compactMap { conversation -> (String, String)? in
            guard let reply = conversation.messages.last, reply.status == .streaming,
                  reply.serverID == nil || reply.serverID == settings.activeID,
                  BotPrefs.notifies(conversation.assistantID),
                  let missionID = reply.missionID, !notified.contains("mission-\(missionID)") else { return nil }
            return (missionID, conversation.title)
        }
        for (missionID, title) in waiting.prefix(5) {
            guard let mission = try? await api.mission(id: missionID), mission.status != "running" else { continue }
            // A mission going in circles stops and asks how to go on: say so, not "failed".
            if let error = mission.error, error.hasPrefix("Je bloque") {
                await post(id: "mission-\(missionID)", title: "Marcel a besoin de toi", body: "\(title) : \(error)")
            } else if mission.status == "done", (mission.actions ?? []).contains(where: \.awaitsApproval) {
                // Like Grok Bot: told when it has finished *or is waiting for you*.
                await post(id: "mission-\(missionID)", title: "Marcel attend ton accord", body: title)
            } else {
                let body = mission.status == "done" ? title : "\(title) : la réponse n'a pas pu aboutir."
                await post(id: "mission-\(missionID)", title: "Marcel a répondu", body: body)
            }
            notified.insert("mission-\(missionID)")
        }

        // New recruitment offers, if the user asked to hear of them (Offres RMA bot).
        if let list = try? await api.offers(), list.notify {
            for offer in list.offers.filter({ $0.isWaiting && !$0.past && !notified.contains("offer-\($0.id)") }).prefix(5) {
                let day = offer.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
                let clash = (offer.dayNote.map { $0.isEmpty ? "" : " · \($0)" } ?? "")
                    + (offer.conflict.isEmpty && offer.portalConflict.isEmpty ? "" : " ⚠️ conflit")
                await post(id: "offer-\(offer.id)", title: "Nouvelle offre RMA · \(day)",
                           body: "\(offer.store) · \(offer.kind) · \(offer.client)\(clash)")
                notified.insert("offer-\(offer.id)")
            }
        }

        // How the answers the user confirmed went in the portal.
        if let list = try? await api.offers() {
            for offer in list.offers where ["done", "failed"].contains(offer.answerStatus)
                && !notified.contains("answer-\(offer.id)") {
                let title = offer.answerStatus == "done"
                    ? (offer.answer == "accept" ? "Mission acceptée ✅" : "Offre refusée")
                    : "Réponse non envoyée ⚠️"
                await post(id: "answer-\(offer.id)", title: title, body: "\(offer.store) · \(offer.answerMessage)")
                notified.insert("answer-\(offer.id)")
            }
        }

        // What Marcel did to his own code: merges, undos, deployments that went back or failed.
        if let log = try? await api.codeLog() {
            let shown = ["fusionnée": "Marcel a fusionné", "annulée": "Fusion annulée",
                         "retour arrière": "Déploiement annulé ⚠️", "déploiement raté": "Serveur en panne ⚠️"]
            let since = UserDefaults.standard.object(forKey: codeLogSeenKey) as? Date ?? .now
            UserDefaults.standard.set(Date.now, forKey: codeLogSeenKey)
            for entry in log.entries.filter({ $0.at > since && shown[$0.action] != nil }).prefix(3) {
                await post(id: "code-\(entry.at.timeIntervalSince1970)", title: shown[entry.action]!, body: entry.detail)
            }
        }

        // The planning may have changed (a mission added or moved): reminders follow it.
        if WorkReminders.isEnabled || MissionCalendar.isEnabled, let missions = try? await api.planning(days: 60) {
            await WorkReminders.schedule(missions)
            MissionCalendar.sync(missions)
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
