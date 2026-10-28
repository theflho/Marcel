import Foundation

/// Events streamed by `GET /v1/missions/{id}/events`.
/// Each SSE `data:` line carries one JSON object: {"type": "delta"|"done"|"stopped"|"error", ...}.
nonisolated enum StreamEvent: Sendable, Equatable {
    /// The full list of the agent's steps, sent again whenever it changes.
    case actions([MissionAction])
    case delta(String)
    case done
    case stopped
    case error(String)
}

/// A reply being generated on the server (`/v1/missions`).
nonisolated struct MissionInfo: Decodable, Sendable, Identifiable {
    let id: String
    let conversationID: String
    let status: String
    /// Length of the text so far, in Unicode code points.
    let length: Int
    let error: String?
    let createdAt: Date
    let finishedAt: Date?
    let model: String?
    let title: String?
    let actions: [MissionAction]?

    enum CodingKeys: String, CodingKey {
        case id, status, length, error, model, title, actions
        case conversationID = "conversation_id"
        case createdAt = "created_at"
        case finishedAt = "finished_at"
    }
}

/// One step of the agent: a command, a file read, a search…
nonisolated struct MissionAction: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String?
    var detail: String?
    /// "running", "done" or "cancelled".
    var status: String?
    /// For what Marcel did himself (a setting, a goal…): what takes it back ("Annuler").
    var undo: ActionUndo?
    /// A web search a bot asks for: the exact question, sent only once the user validates it.
    var query: String?

    /// Something Marcel carried out at the end of his reply, shown as its result.
    var isResult: Bool { id.hasPrefix("auto-") }
    var isHermesApproval: Bool { id.hasPrefix("hermes-approval-") && status == "pending" }
    /// Waits for "Valider" under an "ask first" rule.
    /// Waits for the user: a card under « Demander », or an iPhone request the app could not do
    /// at once (it was closed when the reply ended).
    var awaitsApproval: Bool {
        (id.hasPrefix("auto-ask-") && status == "cancelled") || (id == "iphone-0" && status == "pending")
    }
    /// The rule an approval falls under ("objectif", "routine", "recette", "recherche"), for « Toujours autoriser ».
    var ruleKind: String? {
        guard awaitsApproval else { return nil }
        return id.dropFirst("auto-ask-".count).split(separator: "-").first.map(String.init)
    }
    /// The approval sends the question as a new message, which runs the isolated search.
    var isSearch: Bool { id.hasPrefix("auto-ask-recherche") }
    /// The iPhone asked to read or write something (``query``), waiting for « Autoriser ».
    var isIPhone: Bool { id.hasPrefix("auto-ask-iphone") || id == "iphone-0" }

    /// Not done because the user's rules block that kind of action.
    var isBlocked: Bool { id.hasPrefix("auto-off-") }
}

nonisolated struct RobotScreen: Decodable, Sendable {
    let live: Bool
    let at: Date
    let step: String
    /// JPEG, base64.
    let image: String?
    /// The user holds the portal: the robot leaves it alone.
    let hands: Bool
}

private nonisolated struct RobotHands: Decodable, Sendable {
    let hands: Bool
}

/// "Ask first" rules, per kind of action, like Grok Bot's Always allow / Needs approval / Blocked:
/// "auto" (done, with "Annuler"), "ask" (waits for "Valider") or "off" (not done at all).
nonisolated struct ActionRules: Decodable, Sendable {
    var rules: [String: String]
    let labels: [String: String]
    /// A bot's own levels, where it differs from the general rule.
    var bots: [String: [String: String]]?
    /// Words a web search question must never carry (name, town…), set by the user.
    var privateWords: [String]?
    /// Euros Marcel may pay by himself per purchase (rule « achat »).
    var purchaseCap: Int?
    /// Marcel's own address, for the accounts he creates (nil: no mailbox).
    let mailbox: String?

    enum CodingKeys: String, CodingKey {
        case rules, labels, bots, mailbox
        case privateWords = "private_words"
        case purchaseCap = "purchase_cap"
    }

    /// The level a bot works under for this kind: its own, else the general one.
    func level(_ kind: String, for assistantID: String?) -> String {
        assistantID.flatMap { bots?[$0]?[kind] } ?? rules[kind] ?? "auto"
    }
}

private nonisolated struct RunMarkBody: Encodable {
    let seen: Bool?
    let done: Bool?
}

private nonisolated struct RulesBody: Encodable {
    let rules: [String: String]
    let privateWords: [String]?
    let assistant: String?
    let purchaseCap: Int?

    enum CodingKeys: String, CodingKey {
        case rules, assistant
        case privateWords = "private_words"
        case purchaseCap = "purchase_cap"
    }
}

/// How to take back what Marcel did himself, sent by the server with its card.
nonisolated struct ActionUndo: Codable, Hashable, Sendable {
    /// "reglage", "assistant", "objectif", "routine" or "recette".
    let kind: String
    /// The assistant, goal or routine created.
    var id: String?
    /// For a setting: the assistant, its values before, its mascot before, the instruction added.
    var assistant: String?
    var changes: [String: SettingValue]?
    var mood: String?
    var instruction: String?
}

/// A model the server offers (`GET /v1/models`).
nonisolated struct ModelOption: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let label: String
}

/// One fact in Marcel's memory (`/v1/memory`).
nonisolated struct MemoryFact: Codable, Hashable, Sendable, Identifiable {
    let id: String
    var text: String
    /// "core" (sent with every mission) or "archive" (sent only when related).
    var tier: String
    var importance: Int
    var pinned: Bool
    let source: String
    let createdAt: Date
    let updatedAt: Date
    let lastUsedAt: Date?
    let uses: Int
    let expiresAt: Date?
    /// The bot that learnt it, only that bot sees it (nil or "" = Marcel's, shared by all).
    let owner: String?

    var isCore: Bool { tier == "core" }

    enum CodingKeys: String, CodingKey {
        case id, text, tier, importance, pinned, source, uses, owner
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastUsedAt = "last_used_at"
        case expiresAt = "expires_at"
    }
}

nonisolated struct MemoryStats: Codable, Hashable, Sendable {
    let coreChars: Int
    let coreBudget: Int
    let coreCount: Int
    let archiveCount: Int
    let lastTidy: Date?

    enum CodingKeys: String, CodingKey {
        case coreChars = "core_chars"
        case coreBudget = "core_budget"
        case coreCount = "core_count"
        case archiveCount = "archive_count"
        case lastTidy = "last_tidy"
    }
}

nonisolated struct MemoryList: Decodable, Sendable {
    let stats: MemoryStats
    let items: [MemoryFact]
}

/// One change to the memory, with the text before and after so it can be undone.
nonisolated struct MemoryLogEntry: Decodable, Hashable, Sendable, Identifiable {
    let id: Int
    let at: Date
    /// add, edit, promote, demote, merge, expire, delete.
    let action: String
    let memoryID: String
    let before: String?
    let after: String?
    let tier: String?
    let reason: String
    /// Set for a tidying run or an import: undoing one entry undoes the whole batch.
    let batch: String?
    let undone: Bool

    enum CodingKeys: String, CodingKey {
        case id, at, action, before, after, tier, reason, batch, undone
        case memoryID = "memory_id"
    }
}

nonisolated struct TidySummary: Decodable, Sendable {
    let expired: Int
    let merged: Int
    let promoted: Int
    let demoted: Int
    let stats: MemoryStats
}

/// Something the user wants to accomplish, that Marcel follows (`/v1/goals`).
nonisolated struct Goal: Codable, Hashable, Sendable, Identifiable {
    let id: String
    var title: String
    var detail: String
    /// "proposed" (spotted in a conversation, waiting for the user), "active", "paused", "done" or "dismissed".
    var status: String
    /// How often Marcel should check on it by itself: "daily", "weekly" or "manual".
    var cadence: String
    let conversationID: String
    let createdAt: Date
    let updatedAt: Date
    let lastRunAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, detail, status, cadence
        case conversationID = "conversation_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastRunAt = "last_run_at"
    }
}

/// Fields of a goal to change; nil ones are left as they are.
nonisolated struct GoalChange: Encodable, Sendable {
    var title: String?
    var detail: String?
    var status: String?
    var cadence: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(cadence, forKey: .cadence)
    }

    private enum CodingKeys: String, CodingKey { case title, detail, status, cadence }
}

/// One automatic check of a goal, and what Marcel decided (`/v1/goals/{id}/checks`).
nonisolated struct GoalCheck: Decodable, Hashable, Sendable, Identifiable {
    let id: Int
    let goalID: String
    let missionID: String
    let at: Date
    /// "notify" (an idea was made), "later" (kept in mind), "nothing" (nothing new) or "failed".
    let decision: String
    let summary: String

    enum CodingKeys: String, CodingKey {
        case id, at, decision, summary
        case goalID = "goal_id"
        case missionID = "mission_id"
    }
}

/// Something Marcel found by itself while checking a goal (`/v1/ideas`).
nonisolated struct Idea: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let goalID: String
    let goalTitle: String
    let title: String
    let body: String
    /// An action Marcel prepared, which only happens once the user approves it. Empty if none.
    let action: String
    /// Exactly what would be sent or done (recipient, message, amount…). Nil from older servers.
    let actionDetail: String?
    let importance: Int
    /// "new" (not seen yet), "seen", "opened", "approved" or "dismissed".
    var status: String
    let missionID: String
    var conversationID: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, body, action, importance, status
        case goalID = "goal_id"
        case goalTitle = "goal_title"
        case actionDetail = "action_detail"
        case missionID = "mission_id"
        case conversationID = "conversation_id"
        case createdAt = "created_at"
    }
}

/// A task Marcel runs by itself at a fixed time (`/v1/routines`); its replies go to its own conversation.
nonisolated struct Routine: Codable, Hashable, Sendable, Identifiable {
    let id: String
    var title: String
    var prompt: String
    /// Weekdays it runs on, 0 = Monday ("0,2,4"); empty = every day.
    var days: String
    /// Local time on the server's time zone, "08:00".
    var at: String
    /// "active" or "paused".
    var status: String
    /// The event it waits for instead of the hour ("offre", "planning", "email", "email:sender", "boite", "boite:sender"); "" = at the hour.
    var trigger: String
    let conversationID: String
    /// "Chaque lundi à 8 h", written by the server.
    let schedule: String
    let lastRun: RoutineRun?
    /// The bot it belongs to (a relance, or its standing task); "" for the user's own routines.
    let assistant: String
    let isTask: Bool
    /// When it runs next ("lun. 03/11 à 08:00", "À chaque nouvelle offre", "En pause").
    let next: String?

    var weekdays: Set<Int> { Set(days.split(separator: ",").compactMap { Int($0) }) }

    enum CodingKeys: String, CodingKey {
        case id, title, prompt, days, at, status, schedule, trigger, assistant, next
        case conversationID = "conversation_id"
        case lastRun = "last_run"
        case isTask = "task"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        prompt = try container.decode(String.self, forKey: .prompt)
        days = try container.decode(String.self, forKey: .days)
        at = try container.decode(String.self, forKey: .at)
        status = try container.decode(String.self, forKey: .status)
        // Older servers don't send it.
        trigger = try container.decodeIfPresent(String.self, forKey: .trigger) ?? ""
        conversationID = try container.decode(String.self, forKey: .conversationID)
        schedule = try container.decode(String.self, forKey: .schedule)
        lastRun = try container.decodeIfPresent(RoutineRun.self, forKey: .lastRun)
        assistant = try container.decodeIfPresent(String.self, forKey: .assistant) ?? ""
        isTask = try container.decodeIfPresent(Bool.self, forKey: .isTask) ?? false
        next = try container.decodeIfPresent(String.self, forKey: .next)
    }
}

/// One time a routine ran (`/v1/routines/{id}/runs`, `/v1/routine-runs`).
nonisolated struct RoutineRun: Codable, Hashable, Sendable, Identifiable {
    let id: Int
    let routineID: String
    let missionID: String
    let at: Date
    /// "running", "done" or "failed".
    let status: String
    let error: String
    /// Only in `/v1/routine-runs`: the routine's title and conversation, and the reply.
    let title: String?
    let conversationID: String?
    let text: String?
    let model: String?
    let actions: [MissionAction]?
    /// Set when an assistant relances the user: the reply goes in its conversation, as itself.
    let assistant: String?
    let assistantName: String?

    enum CodingKeys: String, CodingKey {
        case id, at, status, error, title, text, model, actions, assistant
        case assistantName = "assistant_name"
        case routineID = "routine_id"
        case missionID = "mission_id"
        case conversationID = "conversation_id"
    }
}

/// What a bot did on its own (one run of its routines or standing task), like Grok Bot's tasks:
/// read once opened, done once dealt with.
nonisolated struct BotRun: Codable, Hashable, Sendable, Identifiable {
    let id: Int
    let at: Date
    /// "running", "done" or "failed".
    let status: String
    let error: String
    let title: String
    let conversationID: String
    /// A run of its standing task (else of a routine).
    let task: Bool
    var seen: Bool
    var done: Bool

    enum CodingKeys: String, CodingKey {
        case id, at, status, error, title, task, seen, done
        case conversationID = "conversation_id"
    }
}

/// Fields of a routine to change; nil ones are left as they are.
nonisolated struct RoutineChange: Encodable, Sendable {
    var title: String?
    var prompt: String?
    var days: String?
    var at: String?
    var status: String?
    var trigger: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(prompt, forKey: .prompt)
        try container.encodeIfPresent(days, forKey: .days)
        try container.encodeIfPresent(at, forKey: .at)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(trigger, forKey: .trigger)
    }

    private enum CodingKeys: String, CodingKey { case title, prompt, days, at, status, trigger }
}

/// How proactive Marcel is on a server (`/v1/proactive`), with today's counters.
nonisolated struct ProactiveSettings: Decodable, Hashable, Sendable {
    /// "off", "quiet" or "normal".
    var level: String
    /// Ideas allowed per day in normal mode.
    var dailyLimit: Int
    /// Cost ceiling: automatic checks per day.
    var maxChecksPerDay: Int
    let checksToday: Int
    let ideasToday: Int
    let ideasAllowedToday: Int
    let unseen: Int
    /// Hours (server time) during which checks run, e.g. [8, 21].
    let hours: [Int]
    /// Tokens spent today across Hermes, checks and memory, and the daily budget (nil without the LLM guard).
    let tokensToday: Int?
    let tokenBudget: Int?

    enum CodingKeys: String, CodingKey {
        case level, unseen, hours
        case tokensToday = "tokens_today"
        case tokenBudget = "token_budget"
        case dailyLimit = "daily_limit"
        case maxChecksPerDay = "max_checks_per_day"
        case checksToday = "checks_today"
        case ideasToday = "ideas_today"
        case ideasAllowedToday = "ideas_allowed_today"
    }
}

/// One work mission from the RMA planning (`/v1/planning`), read on the server.
nonisolated struct PlanningMission: Decodable, Hashable, Sendable, Identifiable {
    let id: String
    let store: String
    let kind: String
    let client: String
    let startAt: Date
    let endAt: Date

    enum CodingKeys: String, CodingKey {
        case id, store, kind, client
        case startAt = "start_at"
        case endAt = "end_at"
    }
}

/// Fields of the proactivity settings to change; nil ones are left as they are.
/// A setting's value: a number, yes/no or text, as the server sends it.
nonisolated enum SettingValue: Codable, Hashable, Sendable {
    case int(Int), bool(Bool), text(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .int(Int(value)) }
        else { self = .text(try container.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .text(let value): try container.encode(value)
        }
    }
}

/// One of Marcel's assistants (Planning, Pointage, Mails, Veille), tuned in its own conversation.
nonisolated struct Assistant: Decodable, Hashable, Sendable, Identifiable {
    struct Setting: Decodable, Hashable, Sendable, Identifiable {
        struct Choice: Decodable, Hashable, Sendable {
            let value: String
            let label: String
        }

        let key: String
        let label: String
        let kind: String
        let value: SettingValue
        let min: Int
        let max: Int
        let choices: [Choice]
        let help: String
        var id: String { key }

        /// The value as shown to the user ("10", "Oui", "Discrète"…).
        func shown(_ value: SettingValue) -> String {
            switch value {
            // An hour of the day reads "19 h", not "19".
            case .int(let number) where key == "hour" || label.hasPrefix("Heure"): "\(number) h"
            case .int(let number) where help.hasPrefix("minutes"): "\(number) min"
            case .int(let number) where help == "jours": number == 1 ? "1 jour" : "\(number) jours"
            case .int(let number): "\(number)"
            case .bool(let on): on ? "Oui" : "Non"
            case .text(let text):
                choices.first { $0.value == text }?.label ?? (text.isEmpty ? "—" : text)
            }
        }
    }

    struct Instruction: Decodable, Hashable, Sendable, Identifiable {
        let id: String
        let text: String
    }

    /// Something it may read in its conversations (planning, offers…), on or off in its card.
    struct Read: Decodable, Hashable, Sendable, Identifiable {
        let key: String
        let label: String
        let on: Bool
        var id: String { key }
    }

    let id: String
    let name: String
    let emoji: String
    let summary: String
    let welcome: String
    let status: String
    let settings: [Setting]
    let instructions: [Instruction]
    /// Marcel's illustration that stands for it ("coffee", "roadtrip"…).
    let mood: String?
    /// Made by the user from a conversation: it can be deleted.
    let custom: Bool?
    /// A server not updated yet sends none.
    let reads: [Read]?
    /// Tasks the user taught it, which it does again on demand or in its standing task.
    let recipes: [Recipe]?
    /// The shared skills, each ticked or not for this bot.
    let skills: [SkillChoice]?
    /// What it does alone, at its hour or on its event; nil when it has none.
    let task: BotTask?
    /// The RMA automations it carries or could carry (a server not updated yet sends none).
    let automations: [Automation]?

    /// An automation of a system bot (reading the portal, pointage reminders, offer notifications),
    /// which the user can hand to one of their bots and take back. One bot carries it at a time.
    struct Automation: Decodable, Hashable, Sendable, Identifiable {
        let key: String
        let label: String
        let origin: String
        let originName: String
        let owner: String
        let ownerName: String
        let carried: Bool
        var id: String { key }

        enum CodingKeys: String, CodingKey {
            case key, label, origin, owner, carried
            case originName = "origin_name"
            case ownerName = "owner_name"
        }
    }

    /// A task taught once (« Apprends-moi une tâche »): a title and its steps.
    struct Recipe: Decodable, Hashable, Sendable, Identifiable {
        let id: String
        let title: String
        let steps: [String]
    }

    struct SkillChoice: Decodable, Hashable, Sendable, Identifiable {
        let id: String
        let title: String
        let on: Bool
    }

    /// Its standing task, like a Grok Bot that works while the app is closed.
    struct BotTask: Decodable, Hashable, Sendable {
        struct LastRun: Decodable, Hashable, Sendable {
            let at: Date
            /// "running", "done" or "failed".
            let status: String
            let error: String
            let summary: String
        }

        let id: String
        let prompt: String
        /// "" at an hour, else "offre", "planning", "email", "email:sender", "boite" or "boite:sender".
        let trigger: String
        let days: String
        let at: String
        /// "active" or "paused".
        let status: String
        let schedule: String
        let conversationID: String
        let lastRun: LastRun?
        /// When it wakes up next, as said in its card ("lun. 03/11 à 07:30", "À chaque nouvelle offre").
        let next: String

        enum CodingKeys: String, CodingKey {
            case id, prompt, trigger, days, at, status, schedule, next
            case conversationID = "conversation_id"
            case lastRun = "last_run"
        }
    }

    func setting(_ key: String) -> Setting? { settings.first { $0.key == key } }
    /// The server's choice, else the built-in one (a server not updated yet sends none).
    var displayMood: MarcelMood {
        if let chosen = mood.flatMap(MarcelMood.init(rawValue:)) { return chosen }
        switch id {
        case "planning": return .coffee
        case "pointage": return .laptop
        case "recrutements": return .roadtrip
        case "mails": return .reading
        default: return .tree
        }
    }
    var isCustom: Bool { custom ?? false }
    func carries(_ automation: String) -> Bool {
        automations?.first { $0.key == automation }?.carried ?? false
    }
}

/// A recruitment offer from the RMA portal, waiting for the user's answer (`/v1/offers`).
nonisolated struct Offer: Decodable, Hashable, Sendable, Identifiable {
    static let portalURL = URL(string: "https://ecollaborateurs.rmasa.com/#/accueil/missrecrut")!

    let id: String
    let store: String
    let day: Date
    let kind: String
    let client: String
    let agency: String
    /// "open" while it waits for an answer, "gone" once it left the portal's list.
    let status: String
    let startAt: Date?
    let endAt: Date?
    /// What it clashes with in the planning ("déjà en mission à ces heures : …"), or "".
    let conflict: String
    /// The portal's own red warning ("Attention vous avez une autre mission…"), or "".
    let portalConflict: String
    /// False when the portal blocks the answer (a conflict) or its page wasn't read.
    let canAnswer: Bool
    let past: Bool
    /// "Samedi", "Dimanche", "Jour férié : Toussaint"…, or "".
    let dayNote: String?
    /// "accept" or "refuse", once the user confirmed one.
    let answer: String
    /// "pending" (the robot answers within 10 min), "done", "failed", or "".
    let answerStatus: String
    let answerMessage: String

    var isWaiting: Bool { status == "open" && answerStatus != "pending" && answerStatus != "done" }

    enum CodingKeys: String, CodingKey {
        case id, store, day, kind, client, agency, status, conflict, past, answer
        case startAt = "start_at"
        case endAt = "end_at"
        case portalConflict = "portal_conflict"
        case dayNote = "day_note"
        case canAnswer = "can_answer"
        case answerStatus = "answer_status"
        case answerMessage = "answer_message"
    }
}

nonisolated struct OfferEnvelope: Decodable, Sendable {
    let offer: Offer?
}

private nonisolated struct OfferAnswerBody: Encodable, Sendable {
    let answer: String
}

nonisolated struct OfferList: Decodable, Sendable {
    /// The user wants a notification for each new offer (Offres RMA bot).
    let notify: Bool
    let offers: [Offer]
}

/// Blocks the server carries out and the action cards already report: hidden from the text.
nonisolated enum AutoBlocks {
    static func strip(_ text: String) -> String {
        text.replacingOccurrences(of: "```(objectif|routine|recette|demande-code|pour-marcel|automatisme|suivi|recherche|iphone)[\\s\\S]*?```", with: "", options: .regularExpression)
            // The follow-ups come last: hidden while they are still being written too.
            .replacingOccurrences(of: "```suivi[\\s\\S]*$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The questions the user might ask next, which Marcel ends a reply with (a "suivi" block).
nonisolated enum Followups {
    static func find(in text: String) -> [String] {
        guard let start = text.range(of: "```suivi") else { return [] }
        let after = text[start.upperBound...]
        guard let end = after.range(of: "```"),
              let list = try? JSONDecoder().decode([String].self, from: Data(after[..<end.lowerBound].utf8)) else { return [] }
        return list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && $0.count <= 80 }.prefix(2).map { $0 }
    }
}

/// A big change to the app's own code Marcel wrote down for a coding agent (Claude Code or Codex);
/// it leaves only on "Envoyer à …".
nonisolated struct CodeRequestDraft: Codable, Hashable, Sendable {
    let titre: String
    let demande: String

    private static let fence = "```demande-code"

    /// The request in a reply, if there is a readable one (the block itself is hidden by AutoBlocks).
    static func find(in text: String) -> CodeRequestDraft? {
        guard let start = text.range(of: fence) else { return nil }
        let after = text[start.upperBound...]
        guard let end = after.range(of: "```") else { return nil }
        let draft = try? JSONDecoder().decode(CodeRequestDraft.self, from: Data(after[..<end.lowerBound].utf8))
        return draft.flatMap { $0.titre.isEmpty || $0.demande.isEmpty ? nil : $0 }
    }
}

/// What a bot can't do (it has no tool) and hands to Marcel, who has them: a ```pour-marcel``` block.
/// It leaves only when the user touches « Demander à Marcel ».
nonisolated struct MarcelHandoff: Codable, Hashable, Sendable {
    let demande: String

    private static let fence = "```pour-marcel"

    static func find(in text: String) -> MarcelHandoff? {
        guard let start = text.range(of: fence) else { return nil }
        let after = text[start.upperBound...]
        guard let end = after.range(of: "```") else { return nil }
        let found = try? JSONDecoder().decode(MarcelHandoff.self, from: Data(after[..<end.lowerBound].utf8))
        return found.flatMap { $0.demande.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }
}

/// Handing an RMA automation to another bot (or back), proposed by Marcel or a bot in an
/// ```automatisme``` block: it happens only when the user touches « Confier ».
nonisolated struct HandOverProposal: Codable, Hashable, Sendable {
    /// "lecture", "pointage" or "offres".
    let automatisme: String
    /// The bot's id or name; "ici" for the bot of this conversation.
    let bot: String

    private static let fence = "```automatisme"

    static func find(in text: String) -> HandOverProposal? {
        guard let start = text.range(of: fence) else { return nil }
        let after = text[start.upperBound...]
        guard let end = after.range(of: "```") else { return nil }
        return try? JSONDecoder().decode(HandOverProposal.self, from: Data(after[..<end.lowerBound].utf8))
    }
}

/// A code request sent to GitHub, and where it stands (`/v1/code-requests`).
nonisolated struct CodeRequest: Decodable, Hashable, Sendable, Identifiable {
    let id: String
    let title: String
    let body: String
    let issueNumber: Int?
    let issueURL: String
    /// "en cours", "pr", "fusionnee", "fermee" or "inconnu". Nil right after sending.
    let state: String?
    let prURL: String?
    let prTitle: String?
    let createdAt: Date
    /// "claude" or "codex"; nil from an older server.
    let agent: String?

    enum CodingKeys: String, CodingKey {
        case id, title, body, state, agent
        case issueNumber = "issue_number"
        case issueURL = "issue_url"
        case prURL = "pr_url"
        case prTitle = "pr_title"
        case createdAt = "created_at"
    }
}

nonisolated struct CodeRequestList: Decodable, Sendable {
    /// The server has a GitHub repository and key for them.
    let configured: Bool
    let repo: String
    let requests: [CodeRequest]
    /// The coding agent new requests go to, and the ones the server knows.
    let agent: String?
    let agents: [CodeAgent]?
}

nonisolated struct CodeAgent: Decodable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
}

/// One thing Marcel did to his own code: a pull request proposed or merged, a deployment, a rollback.
nonisolated struct CodeLogEntry: Decodable, Sendable, Identifiable {
    let at: Date
    let action: String
    let detail: String
    let url: String?
    /// The pull request it's about (merges can be undone from the app).
    let number: Int?

    var id: Date { at }
}

nonisolated struct CodeLog: Decodable, Sendable {
    let configured: Bool
    let entries: [CodeLogEntry]
}

/// An assistant Marcel proposed to create in a conversation ("Créer l'assistant").
nonisolated struct AssistantDraft: Codable, Hashable, Sendable {
    let nom: String
    let mission: String
    let illustration: String?

    var mood: MarcelMood { illustration.flatMap(MarcelMood.init(rawValue:)) ?? .tree }

    private static let fence = "```assistant"

    /// The reply without the draft's block, and the draft, if there is a readable one.
    static func split(_ text: String) -> (text: String, draft: AssistantDraft?) {
        guard let start = text.range(of: fence) else { return (text, nil) }
        let after = text[start.upperBound...]
        let end = after.range(of: "```")
        let rest = String(text[..<start.lowerBound]) + (end.map { String(after[$0.upperBound...]) } ?? "")
        let json = end.map { String(after[..<$0.lowerBound]) }
        let draft = json.flatMap { try? JSONDecoder().decode(AssistantDraft.self, from: Data($0.utf8)) }
        let usable = draft.flatMap { $0.nom.isEmpty || $0.mission.isEmpty ? nil : $0 }
        return (rest.trimmingCharacters(in: .whitespacesAndNewlines), usable)
    }
}

private nonisolated struct AssistantCreate: Encodable, Sendable {
    let name: String
    let mission: String
    let mood: String
}

private nonisolated struct DeletedAssistant: Decodable, Sendable {
    let deleted: String
}

/// A change an assistant proposed in its conversation, applied only when the user taps "Appliquer".
nonisolated struct AssistantProposal: Codable, Hashable, Sendable {
    /// Which assistant, when Marcel proposes it from one of his own conversations.
    var assistant: String?
    var changes: [String: SettingValue] = [:]
    /// Things to do right away ("relire": read the portal now).
    var actions: [String] = []
    var consigne: String = ""
    var resume: String = ""

    enum CodingKeys: String, CodingKey { case assistant, changes, actions, consigne, resume }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assistant = try? container.decodeIfPresent(String.self, forKey: .assistant)
        changes = (try? container.decodeIfPresent([String: SettingValue].self, forKey: .changes)) ?? [:]
        actions = (try? container.decodeIfPresent([String].self, forKey: .actions)) ?? []
        consigne = (try? container.decodeIfPresent(String.self, forKey: .consigne)) ?? ""
        resume = (try? container.decodeIfPresent(String.self, forKey: .resume)) ?? ""
    }

    var isEmpty: Bool {
        changes.isEmpty && actions.isEmpty && consigne.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func label(ofAction action: String) -> String {
        action == "relire" ? "Relire le portail RMA maintenant" : action
    }

    private static let fence = "```reglage"

    /// The reply without its proposal block, and the proposal, if there is a readable one.
    static func split(_ text: String) -> (text: String, proposal: AssistantProposal?) {
        guard let start = text.range(of: fence) else { return (text, nil) }
        let after = text[start.upperBound...]
        let end = after.range(of: "```")
        let json = String(end.map { after[..<$0.lowerBound] } ?? after)
        let rest = String(text[..<start.lowerBound]) + (end.map { String(after[$0.upperBound...]) } ?? "")
        let proposal = end == nil ? nil : try? JSONDecoder().decode(AssistantProposal.self, from: Data(json.utf8))
        return (rest.trimmingCharacters(in: .whitespacesAndNewlines), proposal?.isEmpty == false ? proposal : nil)
    }
}

private nonisolated struct AssistantUpdate: Encodable, Sendable {
    let changes: [String: SettingValue]
    let instruction: String?
    let actions: [String]
    let mood: String?
    let reads: [String]?
    let skills: [String]?
}

/// A bot's standing task as the user sets it in its card (`PUT /v1/assistants/{id}/task`).
nonisolated struct BotTaskChange: Encodable, Sendable {
    var prompt: String
    var trigger: String
    var days: String
    var at: String
    var status: String
    var conversationID: String

    enum CodingKeys: String, CodingKey {
        case prompt, trigger, days, at, status
        case conversationID = "conversation_id"
    }
}

private nonisolated struct RecipeChange: Encodable, Sendable {
    let title: String
    let steps: [String]
}

/// A skill shared between bots (`/v1/bot-skills`): plain text the user writes once.
nonisolated struct BotSkill: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let title: String
    let text: String
    /// The bots that use it.
    let bots: [String]
}

private nonisolated struct SkillChange: Encodable, Sendable {
    let title: String
    let text: String
}

private nonisolated struct DeletedSkill: Decodable, Sendable {
    let deleted: String
}

nonisolated struct ReceivedFile: Decodable, Hashable, Sendable {
    let id: String
    let filename: String
    let mimeType: String
    let size: Int

    enum CodingKeys: String, CodingKey {
        case id, filename, size
        case mimeType = "mime_type"
    }
}

/// What the user said to a bot outside the app (Telegram) and its reply (`/v1/bot-messages`).
nonisolated struct BotMessage: Decodable, Hashable, Sendable, Identifiable {
    let id: Int
    let assistant: String
    let assistantName: String
    let conversationID: String
    let question: String
    let missionID: String
    let at: Date
    let text: String
    let model: String?
    let actions: [MissionAction]?
    let status: String
    let via: String
    let attachments: [ReceivedFile]?

    enum CodingKeys: String, CodingKey {
        case id, assistant, question, at, text, model, actions, status, via, attachments
        case assistantName = "assistant_name"
        case conversationID = "conversation_id"
        case missionID = "mission_id"
    }
}

private nonisolated struct DeliveredBotMessage: Decodable, Sendable {
    let delivered: Int
}

/// A bot's page (`/v1/assistants/{id}/page`): a table the server works out at each opening,
/// without any model. Empty markdown for a bot that has none.
nonisolated struct BotPage: Decodable, Hashable, Sendable {
    let title: String
    let markdown: String
    let at: Date
}

nonisolated struct ProactiveChange: Encodable, Sendable {
    var level: String?
    var dailyLimit: Int?
    var maxChecksPerDay: Int?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(level, forKey: .level)
        try container.encodeIfPresent(dailyLimit, forKey: .dailyLimit)
        try container.encodeIfPresent(maxChecksPerDay, forKey: .maxChecksPerDay)
    }

    private enum CodingKeys: String, CodingKey {
        case level
        case dailyLimit = "daily_limit"
        case maxChecksPerDay = "max_checks_per_day"
    }
}

/// Fields of a fact to change; nil ones are left as they are.
nonisolated struct MemoryChange: Encodable, Sendable {
    var text: String?
    var tier: String?
    var importance: Int?
    var pinned: Bool?
    /// Moves it: "" to the shared memory, a bot's id to that bot's own.
    var owner: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(tier, forKey: .tier)
        try container.encodeIfPresent(importance, forKey: .importance)
        try container.encodeIfPresent(pinned, forKey: .pinned)
        try container.encodeIfPresent(owner, forKey: .owner)
    }

    enum CodingKeys: String, CodingKey { case text, tier, importance, pinned, owner }
}

/// Tokens spent today on the model, across Hermes, checks and memory (`/health`, from the LLM guard).
nonisolated struct TokenUsage: Decodable, Equatable, Sendable {
    let today: Int
    let budget: Int

    var fraction: Double { budget > 0 ? min(Double(today) / Double(budget), 1) : 0 }
    var summary: String {
        "\(today.formatted(.number.notation(.compactName))) / \(budget.formatted(.number.notation(.compactName)))"
    }
}

nonisolated struct HermesCapabilities: Decodable, Sendable {
    struct Toolset: Decodable, Sendable {
        let name: String
        let label: String
        let enabled: Bool
        let configured: Bool
        let tools: [String]
    }
    struct Skill: Decodable, Sendable {
        let name: String
        let description: String
        let category: String
    }
    let profile: String
    let ready: Bool
    let toolsets: [Toolset]
    let skills: [Skill]
    let issues: [String]
}

nonisolated struct ServerHealth: Sendable {
    let status: Int
    /// The server-side emergency stop is on: it refuses every mission.
    let emergency: Bool
    /// Ideas Marcel found that the user hasn't seen yet.
    let unseenIdeas: Int
    /// Nil when the server has no LLM guard.
    let tokens: TokenUsage?
    let resetID: String?
}

nonisolated enum MarcelAPIError: LocalizedError {
    case notConfigured
    case unauthorized
    case missionNotFound
    case emergency
    case http(Int, String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Adresse du serveur non configurée."
        case .unauthorized: "Jeton refusé par le serveur."
        case .missionNotFound: "Mission introuvable sur le serveur."
        case .emergency: "Arrêt d'urgence actif : aucune mission ne peut démarrer."
        // The server's details are written for the user; the code alone means nothing to them.
        case .http(let code, let body): body.isEmpty ? "Le serveur a répondu par une erreur (\(code))." : body
        case .server(let message): message
        }
    }
}

nonisolated struct MarcelAPI: Sendable {
    let baseURL: URL
    let token: String?

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// `GET /health`, or nil when the server can't be reached.
    func health() async -> ServerHealth? {
        var request = URLRequest(url: baseURL.appending(path: "health"), timeoutInterval: 5)
        authorize(&request)
        guard let (data, response) = try? await Self.session.data(for: request) else { return nil }
        let body = try? JSONDecoder().decode(HealthBody.self, from: data)
        return ServerHealth(status: (response as? HTTPURLResponse)?.statusCode ?? 0, emergency: body?.emergency ?? false,
                            unseenIdeas: body?.ideas ?? 0, tokens: body?.tokens, resetID: body?.resetID)
    }

    func models() async throws -> [ModelOption] {
        var request = URLRequest(url: baseURL.appending(path: "v1/models"), timeoutInterval: 10)
        authorize(&request)
        let (data, response) = try await Self.session.data(for: request)
        try Self.check(response, body: data)
        return try JSONDecoder().decode(ModelList.self, from: data).models
    }

    func mission(id: String) async throws -> MissionInfo {
        try await call("GET", "v1/missions/\(id)")
    }

    func missions() async throws -> [MissionInfo] {
        var request = URLRequest(url: baseURL.appending(path: "v1/missions"), timeoutInterval: 10)
        authorize(&request)
        let (data, response) = try await Self.session.data(for: request)
        try Self.check(response, body: data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode([MissionInfo].self, from: data)
    }

    /// Server-wide emergency stop: cuts every mission and blocks new ones until resumed.
    func setEmergency(_ active: Bool) async throws {
        var request = URLRequest(url: baseURL.appending(path: active ? "v1/emergency/stop" : "v1/emergency/resume"),
                                 timeoutInterval: 15)
        request.httpMethod = "POST"
        authorize(&request)
        let (data, response) = try await Self.session.data(for: request)
        try Self.check(response, body: data)
    }

    /// Starts generating the reply on the server. Returns as soon as the mission exists.
    func startMission(conversationID: UUID, messages: [ChatMessage], model: String?,
                      deviceContext: String? = nil, assistant: String? = nil,
                      isPrivate: Bool = false, style: String = "", search: String = "") async throws -> MissionInfo {
        var request = URLRequest(url: baseURL.appending(path: "v1/missions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            conversationId: conversationID.uuidString,
            messages: messages.map {
                .init(role: $0.role.rawValue,
                      content: $0.content + ($0.role == .assistant && !$0.attachments.isEmpty
                          ? "\nFichiers joints : " + $0.attachments.map(\.filename).joined(separator: ", ") : ""),
                      attachments: $0.role == .user ? $0.attachments.compactMap(\.remoteID) : [])
            },
            model: model,
            deviceContext: deviceContext,
            assistant: assistant,
            isPrivate: isPrivate,
            style: style,
            search: search
        ))
        let (data, response) = try await Self.session.data(for: request)
        try Self.check(response, body: data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(MissionInfo.self, from: data)
    }

    // MARK: Memory

    func memory(query: String? = nil) async throws -> MemoryList {
        let items = query.map { [URLQueryItem(name: "q", value: $0)] } ?? []
        return try await call("GET", "v1/memory", query: items)
    }

    func addMemory(text: String, tier: String) async throws -> MemoryFact {
        try await call("POST", "v1/memory", body: ["text": text, "tier": tier])
    }

    func updateMemory(id: String, _ change: MemoryChange) async throws -> MemoryFact {
        try await call("PATCH", "v1/memory/\(id)", body: change)
    }

    func deleteMemory(id: String) async throws {
        let _: MemoryFact = try await call("DELETE", "v1/memory/\(id)")
    }

    func memoryLog() async throws -> [MemoryLogEntry] {
        try await call("GET", "v1/memory/log")
    }

    func undoMemory(entryID: Int) async throws {
        let _: UndoResult = try await call("POST", "v1/memory/log/\(entryID)/undo")
    }

    func tidyMemory() async throws -> TidySummary {
        try await call("POST", "v1/memory/tidy")
    }

    // MARK: Goals

    /// Every goal except the dismissed ones, or only those with `status`.
    func goals(status: String? = nil, conversationID: UUID? = nil) async throws -> [Goal] {
        var items: [URLQueryItem] = []
        if let status { items.append(URLQueryItem(name: "status", value: status)) }
        if let conversationID { items.append(URLQueryItem(name: "conversation_id", value: conversationID.uuidString)) }
        return try await call("GET", "v1/goals", query: items)
    }

    func addGoal(title: String, detail: String, cadence: String) async throws -> Goal {
        try await call("POST", "v1/goals", body: ["title": title, "detail": detail, "cadence": cadence])
    }

    func updateGoal(id: String, _ change: GoalChange) async throws -> Goal {
        try await call("PATCH", "v1/goals/\(id)", body: change)
    }

    func deleteGoal(id: String) async throws {
        let _: Goal = try await call("DELETE", "v1/goals/\(id)")
    }

    /// Checks a followed goal now, whatever its rhythm. Returns the check's mission.
    func checkGoal(id: String) async throws -> MissionInfo {
        try await call("POST", "v1/goals/\(id)/check")
    }

    func goalChecks(id: String) async throws -> [GoalCheck] {
        try await call("GET", "v1/goals/\(id)/checks")
    }

    // MARK: Ideas

    /// Every idea except the dismissed ones.
    func ideas() async throws -> [Idea] {
        try await call("GET", "v1/ideas")
    }

    /// The user saw the list: new ideas become seen (the badge goes away).
    func markIdeasSeen() async throws {
        let _: SeenResult = try await call("POST", "v1/ideas/seen")
    }

    /// "opened" (with the conversation it became) or "dismissed" (remembered as not interesting).
    func updateIdea(id: String, status: String, conversationID: UUID? = nil) async throws -> Idea {
        var body = ["status": status]
        if let conversationID { body["conversation_id"] = conversationID.uuidString }
        return try await call("PATCH", "v1/ideas/\(id)", body: body)
    }

    func deleteIdea(id: String) async throws {
        let _: Idea = try await call("DELETE", "v1/ideas/\(id)")
    }

    // MARK: Code requests

    func codeRequests() async throws -> CodeRequestList {
        try await call("GET", "v1/code-requests")
    }

    func setCodeAgent(_ agent: String) async throws {
        let _: [String: String] = try await call("PUT", "v1/code-requests/agent", body: ["agent": agent])
    }

    /// Undoes a merged pull request of Marcel's; returns what the server says.
    func revertCode(number: Int) async throws -> String {
        let reply: [String: String] = try await call("POST", "v1/code/revert", body: ["number": number])
        return reply["message"] ?? ""
    }

    func codeLog() async throws -> CodeLog {
        try await call("GET", "v1/code-log")
    }

    /// Opens the GitHub issue for the request in that reply of Marcel (read by the server from the reply).
    func sendCodeRequest(missionID: String) async throws -> CodeRequest {
        try await call("POST", "v1/code-requests", body: ["mission_id": missionID])
    }

    // MARK: Robot

    /// What the RMA robot's browser shows right now (inputs masked by the robot).
    func robotScreen() async throws -> RobotScreen {
        try await call("GET", "v1/robot/screen")
    }

    /// "Je prends la main" (true) or "Je rends la main" (false).
    func holdRobot(_ hold: Bool) async throws {
        let _: RobotHands = try await call("POST", "v1/robot/hands", body: ["hold": hold])
    }

    // MARK: Rules

    func hermesCapabilities(assistant: String? = nil) async throws -> HermesCapabilities {
        try await call("GET", "v1/hermes/capabilities",
                       query: assistant.map { [URLQueryItem(name: "assistant", value: $0)] } ?? [])
    }

    func hermesApproval(mission: String, action: String, choice: String) async throws -> MissionAction {
        try await call("POST", "v1/missions/\(mission)/hermes-approval/\(action)", body: ["choice": choice])
    }

    func rules() async throws -> ActionRules {
        try await call("GET", "v1/rules")
    }

    /// With a bot: its own levels ("" puts the general rule back for that kind).
    func setRules(_ rules: [String: String], privateWords: [String]? = nil, assistant: String? = nil,
                  purchaseCap: Int? = nil) async throws -> ActionRules {
        try await call("PUT", "v1/rules", body: RulesBody(rules: rules, privateWords: privateWords, assistant: assistant,
                                                          purchaseCap: purchaseCap))
    }

    /// "Valider" on what waited for the user's go-ahead. Returns the card, now done (with "Annuler").
    func approve(card: String, missionID: String) async throws -> MissionAction {
        try await call("POST", "v1/missions/\(missionID)/approve", body: ["card": card])
    }

    // MARK: Routines

    func routines() async throws -> [Routine] {
        try await call("GET", "v1/routines")
    }

    func addRoutine(_ routine: RoutineChange) async throws -> Routine {
        try await call("POST", "v1/routines", body: routine)
    }

    func updateRoutine(id: String, _ change: RoutineChange) async throws -> Routine {
        try await call("PATCH", "v1/routines/\(id)", body: change)
    }

    func deleteRoutine(id: String) async throws {
        let _: Routine = try await call("DELETE", "v1/routines/\(id)")
    }

    /// Runs a routine now, whatever its hour. Returns its mission.
    func runRoutine(id: String) async throws -> MissionInfo {
        try await call("POST", "v1/routines/\(id)/run")
    }

    func routineRuns(id: String) async throws -> [RoutineRun] {
        try await call("GET", "v1/routines/\(id)/runs")
    }

    func botRuns(assistantID: String) async throws -> [BotRun] {
        try await call("GET", "v1/assistants/\(assistantID)/runs")
    }

    /// Read or done; nil leaves it as it is (done is read too).
    func markRun(id: Int, seen: Bool? = nil, done: Bool? = nil) async throws -> BotRun {
        try await call("POST", "v1/routine-runs/\(id)/mark", body: RunMarkBody(seen: seen, done: done))
    }

    /// Finished runs not yet put in their conversation on this iPhone, with their reply.
    func pendingRoutineRuns() async throws -> [RoutineRun] {
        try await call("GET", "v1/routine-runs")
    }

    func markRoutineRunDelivered(id: Int) async throws {
        let _: [String: Int] = try await call("POST", "v1/routine-runs/\(id)/delivered")
    }

    /// Work missions from yesterday to `days` ahead.
    func planning(days: Int = 14) async throws -> [PlanningMission] {
        try await call("GET", "v1/planning", query: [URLQueryItem(name: "days", value: String(days))])
    }

    // MARK: Assistants

    func assistants() async throws -> [Assistant] {
        try await call("GET", "v1/assistants")
    }

    /// Saves settings and/or an instruction; the server checks them against their bounds.
    func updateAssistant(id: String, changes: [String: SettingValue], instruction: String? = nil,
                         actions: [String] = [], mood: String? = nil, reads: [String]? = nil,
                         skills: [String]? = nil) async throws -> Assistant {
        try await call("PATCH", "v1/assistants/\(id)",
                       body: AssistantUpdate(changes: changes, instruction: instruction, actions: actions, mood: mood,
                                             reads: reads, skills: skills))
    }

    func setTask(assistantID: String, _ change: BotTaskChange) async throws -> Assistant {
        try await call("PUT", "v1/assistants/\(assistantID)/task", body: change)
    }

    func deleteTask(assistantID: String) async throws -> Assistant {
        try await call("DELETE", "v1/assistants/\(assistantID)/task")
    }

    /// Runs the standing task now: its result comes back like a routine's.
    func runTask(assistantID: String) async throws {
        let _: MissionInfo = try await call("POST", "v1/assistants/\(assistantID)/task/run")
    }

    func updateRecipe(assistantID: String, id: String, title: String, steps: [String]) async throws -> Assistant {
        try await call("PUT", "v1/assistants/\(assistantID)/recipes/\(id)", body: RecipeChange(title: title, steps: steps))
    }

    func deleteRecipe(assistantID: String, id: String) async throws -> Assistant {
        try await call("DELETE", "v1/assistants/\(assistantID)/recipes/\(id)")
    }

    func botSkills() async throws -> [BotSkill] {
        try await call("GET", "v1/bot-skills")
    }

    func addBotSkill(title: String, text: String) async throws -> BotSkill {
        try await call("POST", "v1/bot-skills", body: SkillChange(title: title, text: text))
    }

    func updateBotSkill(id: String, title: String, text: String) async throws -> BotSkill {
        try await call("PUT", "v1/bot-skills/\(id)", body: SkillChange(title: title, text: text))
    }

    func deleteBotSkill(id: String) async throws {
        let _: DeletedSkill = try await call("DELETE", "v1/bot-skills/\(id)")
    }

    func pendingBotMessages() async throws -> [BotMessage] {
        try await call("GET", "v1/bot-messages")
    }

    func markBotMessageDelivered(id: Int) async throws {
        let _: DeliveredBotMessage = try await call("POST", "v1/bot-messages/\(id)/delivered")
    }

    func botPage(id: String) async throws -> BotPage {
        try await call("GET", "v1/assistants/\(id)/page")
    }

    func createAssistant(_ draft: AssistantDraft) async throws -> Assistant {
        try await call("POST", "v1/assistants",
                       body: AssistantCreate(name: draft.nom, mission: draft.mission, mood: draft.mood.rawValue))
    }

    /// Hands an automation to one of the user's bots, or back to its system bot. Returns every bot.
    func handOver(automation: String, to assistantID: String) async throws -> [Assistant] {
        try await call("PUT", "v1/automations/\(automation)", body: ["assistant": assistantID])
    }

    func deleteAssistant(id: String) async throws {
        let _: DeletedAssistant = try await call("DELETE", "v1/assistants/\(id)")
    }

    func offers() async throws -> OfferList {
        try await call("GET", "v1/offers")
    }

    /// Asks the robot to accept or refuse the offer in the portal (after the user's "Oui").
    func answerOffer(id: String, accept: Bool) async throws {
        let _: OfferEnvelope = try await call("POST", "v1/offers/\(id)/answer",
                                              body: OfferAnswerBody(answer: accept ? "accept" : "refuse"))
    }

    func cancelOfferAnswer(id: String) async throws {
        let _: OfferEnvelope = try await call("DELETE", "v1/offers/\(id)/answer")
    }

    func deleteInstruction(assistantID: String, id: String) async throws -> Assistant {
        try await call("DELETE", "v1/assistants/\(assistantID)/instructions/\(id)")
    }

    func proactive() async throws -> ProactiveSettings {
        try await call("GET", "v1/proactive")
    }

    func updateProactive(_ change: ProactiveChange) async throws -> ProactiveSettings {
        try await call("PATCH", "v1/proactive", body: change)
    }

    /// A JSON request to the backend, decoded with dates in seconds since 1970.
    private func call<Response: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [],
                                           body: (some Encodable)? = Optional<String>.none) async throws -> Response {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.httpMethod = method
        authorize(&request)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await Self.session.data(for: request)
        try Self.check(response, body: data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(Response.self, from: data)
    }

    func cancelMission(id: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "v1/missions/\(id)/cancel"), timeoutInterval: 15)
        request.httpMethod = "POST"
        authorize(&request)
        let (data, response) = try await Self.session.data(for: request)
        try Self.check(response, body: data)
    }

    /// The mission's text from `offset` (Unicode code points), then live until it ends.
    func missionEvents(id: String, offset: Int) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var components = URLComponents(url: baseURL.appending(path: "v1/missions/\(id)/events"),
                                                   resolvingAgainstBaseURL: false)!
                    components.queryItems = [URLQueryItem(name: "offset", value: String(offset))]
                    var request = URLRequest(url: components.url!, timeoutInterval: 60)
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    authorize(&request)

                    let (bytes, response) = try await Self.session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status != 200 {
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 300 { break } }
                        try Self.check(response, body: Data(body.utf8))
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let event = Self.decode(payload) else { continue }
                        continuation.yield(event)
                        if case .delta = event { continue }
                        if case .actions = event { continue }
                        // Done, stopped or error: the mission is over.
                        break
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func check(_ response: URLResponse, body: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return
        case 401, 403: throw MarcelAPIError.unauthorized
        case 404 where String(decoding: body, as: UTF8.self).contains("Mission"): throw MarcelAPIError.missionNotFound
        case 423: throw MarcelAPIError.emergency
        default:
            let detail = (try? JSONDecoder().decode(ErrorDetail.self, from: body))?.detail
            throw MarcelAPIError.http(status, detail ?? String(decoding: body.prefix(300), as: UTF8.self))
        }
    }

    /// Uploads one attachment (`POST /v1/files`, multipart) and returns the server's file id.
    func upload(_ attachment: Attachment, data: Data) async throws -> String {
        let boundary = "marcel-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appending(path: "v1/files"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        authorize(&request)

        let safeName = attachment.filename.replacingOccurrences(of: "\"", with: "'")
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(attachment.mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let (responseData, response) = try await Self.session.upload(for: request, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw MarcelAPIError.unauthorized }
        guard status == 200 else {
            throw MarcelAPIError.http(status, String(decoding: responseData.prefix(300), as: UTF8.self))
        }
        return try JSONDecoder().decode(UploadResponse.self, from: responseData).id
    }

    func download(_ file: ReceivedFile) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: "v1/files/\(file.id)/content"), timeoutInterval: 60)
        authorize(&request)
        let (data, response) = try await Self.session.data(for: request)
        try Self.check(response, body: data)
        guard data.count <= AttachmentStore.maxBytes else { throw AttachmentError.tooLarge }
        guard data.count == file.size else { throw AttachmentError.incompleteDownload }
        return data
    }

    private func authorize(_ request: inout URLRequest) {
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    static func decode(_ payload: String) -> StreamEvent? {
        guard let data = payload.data(using: .utf8),
              let wire = try? JSONDecoder().decode(WireEvent.self, from: data) else { return nil }
        switch wire.type {
        case "actions": return .actions(wire.actions ?? [])
        case "delta": return .delta(wire.text ?? "")
        case "done": return .done
        case "stopped": return .stopped
        case "error": return .error(wire.message ?? "Erreur inconnue du serveur.")
        default: return nil
        }
    }
}

private nonisolated struct ChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
        let attachments: [String]
    }

    let conversationId: String
    let messages: [Message]
    let model: String?
    /// Read-only information the iPhone shares, when the user allowed it (upcoming events).
    let deviceContext: String?
    /// The assistant whose conversation this is (Planning, Pointage…), if any.
    let assistant: String?
    /// No memory read nor learnt, the reply never searched again.
    let isPrivate: Bool
    let style: String
    /// A web search the user validated in a bot's conversation.
    let search: String

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case deviceContext = "device_context"
        case isPrivate = "private"
        case messages, model, assistant, style, search
    }
}

private nonisolated struct UndoResult: Decodable {
    let undone: Int
}

private nonisolated struct HealthBody: Decodable {
    let emergency: Bool?
    let ideas: Int?
    let tokens: TokenUsage?
    let resetID: String?
    enum CodingKeys: String, CodingKey {
        case emergency, ideas, tokens
        case resetID = "reset_id"
    }
}

private nonisolated struct SeenResult: Decodable {
    let seen: Int
}

private nonisolated struct ModelList: Decodable {
    let models: [ModelOption]
}

private nonisolated struct ErrorDetail: Decodable {
    let detail: String
}

private nonisolated struct UploadResponse: Decodable {
    let id: String
}

private nonisolated struct WireEvent: Decodable {
    let type: String
    let text: String?
    let message: String?
    let actions: [MissionAction]?
}
