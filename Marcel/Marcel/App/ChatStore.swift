import Foundation
import Observation

enum ServerStatus: Equatable {
    case unknown, checking, reachable, unauthorized, unreachable
}

/// A place in Settings the app can open directly, e.g. from an error about it.
enum SettingsRoute: Hashable {
    case server(UUID)
    case proactive
}

/// What the user can do about the last error, shown as a button next to it.
enum ErrorAction: Equatable {
    case openSettings(SettingsRoute, label: String)
    case retry

    var label: String {
        switch self {
        case .openSettings(_, let label): label
        case .retry: "Réessayer"
        }
    }
}

@Observable
final class ChatStore {
    private static let draftKey = "draft"
    private static let emergencyKey = "emergencyStop"
    private static let modelChoiceKey = "modelChoice"

    let settings: ServerSettings
    /// Reads replies aloud, on the iPhone.
    let speaker = Speaker()
    private let cache = ConversationCache()
    /// One task per conversation following its reply, so switching conversations never cuts an answer.
    private var streamTasks: [UUID: Task<Void, Never>] = [:]
    /// The web search question the next message carries, once the user validated it.
    @ObservationIgnored private var pendingSearch: String?

    private(set) var conversations: [Conversation]
    private(set) var projects: [Project]
    private(set) var currentID: UUID {
        didSet { if oldValue != currentID { dropPrivate(oldValue) } }
    }
    private(set) var serverStatus: ServerStatus = .unknown
    private(set) var lastError: String? {
        didSet { lastErrorAction = nil }
    }
    private(set) var lastErrorAction: ErrorAction?
    /// Today's token usage on the active server, refreshed with each health check and after replies.
    private(set) var tokenUsage: TokenUsage?
    /// Set to open Settings at a given place; SettingsView takes it when it appears.
    var settingsRequest: SettingsRoute?
    private var lastPlanningSync: Date?

    var draft: String {
        didSet { UserDefaults.standard.set(draft, forKey: Self.draftKey) }
    }

    /// Emergency stop: while on, the app sends no request at all, not even health checks.
    private(set) var emergencyActive: Bool {
        didSet { UserDefaults.standard.set(emergencyActive, forKey: Self.emergencyKey) }
    }

    /// Models offered by the active server, and the one picked for each server.
    private(set) var models: [ModelOption] = []
    /// Goals Marcel spotted in the current conversation, waiting for the user to accept or decline.
    private(set) var goalProposals: [Goal] = []
    /// Ideas Marcel found on its own that the user hasn't looked at yet (badge in the header).
    private(set) var unseenIdeas = 0
    /// Marcel's assistants (Planning, Pointage, Mails, Veille): modes a conversation can talk to.
    private(set) var assistants: [Assistant] = []
    /// Recruitment offers waiting for an answer, shown in the Offres RMA bot's conversations.
    private(set) var offers: [Offer] = []
    /// The work planning, to show each offer's week and clashes.
    private(set) var planningMissions: [PlanningMission] = []
    private var modelChoice: [String: String] {
        didSet { UserDefaults.standard.set(modelChoice, forKey: Self.modelChoiceKey) }
    }

    /// Photos and files waiting in the composer for the next message.
    private(set) var pendingAttachments: [Attachment] = []
    private(set) var isPreparingAttachment = false

    init(settings: ServerSettings) {
        self.settings = settings
        var loaded = cache.loadAll()
        // Replies with a server mission are followed again once the server answers;
        // one cut off before its mission started can't be recovered.
        for c in loaded.indices {
            for m in loaded[c].messages.indices
            where loaded[c].messages[m].status == .streaming && loaded[c].messages[m].missionID == nil {
                loaded[c].messages[m].status = .stopped
            }
        }
        // An assistant's old conversation that never went past its welcome: the welcome view says it now.
        for stale in loaded where stale.assistantID != nil && !stale.messages.contains(where: { $0.role == .user }) {
            cache.delete(stale.id)
        }
        loaded.removeAll { $0.assistantID != nil && !$0.messages.contains { $0.role == .user } }
        if loaded.isEmpty { loaded = [Conversation()] }
        conversations = loaded
        projects = cache.loadProjects()
        currentID = loaded[0].id
        draft = UserDefaults.standard.string(forKey: Self.draftKey) ?? ""
        emergencyActive = UserDefaults.standard.bool(forKey: Self.emergencyKey)
        modelChoice = UserDefaults.standard.dictionary(forKey: Self.modelChoiceKey) as? [String: String] ?? [:]
    }

    // MARK: - Current conversation

    var conversation: Conversation {
        conversations.first { $0.id == currentID } ?? Conversation()
    }

    var isStreaming: Bool { isStreaming(currentID) }

    /// Replies being written right now, across all conversations.
    var runningReplies: Int {
        conversations.filter { $0.messages.last?.status == .streaming }.count
    }

    /// True while the reply is being generated, even if the app isn't connected to it right now.
    func isStreaming(_ id: UUID) -> Bool {
        streamTasks[id] != nil || conversations.first { $0.id == id }?.messages.last?.status == .streaming
    }

    var canSend: Bool {
        !isStreaming && !isPreparingAttachment && !emergencyActive
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty)
    }

    func project(for conversation: Conversation) -> Project? {
        projects.first { $0.id == conversation.projectID }
    }

    // MARK: - Conversations

    /// Conversations worth listing, whatever their mode: any that have messages.
    var listedConversations: [Conversation] {
        conversations
            .filter { !$0.messages.isEmpty && !$0.isPrivate }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// A private conversation: nothing kept on the iPhone nor learnt on the server.
    /// Réglages › Réponses: "" (normal), "concis" or "detaille", sent with each message.
    static let replyStyleKey = "replyStyle"

    func newPrivateConversation() {
        dropCurrentIfEmpty()
        let fresh = Conversation(title: "Conversation privée", isPrivate: true)
        conversations.append(fresh)
        currentID = fresh.id
        lastError = nil
        goalProposals = []
    }

    /// Leaving a private conversation erases it.
    private func dropPrivate(_ id: UUID) {
        guard let conversation = conversations.first(where: { $0.id == id }), conversation.isPrivate else { return }
        streamTasks[id]?.cancel()
        AttachmentStore.delete(conversation.messages.flatMap(\.attachments))
        conversations.removeAll { $0.id == id }
    }

    func select(_ id: UUID) {
        guard id != currentID else { return }
        dropCurrentIfEmpty()
        currentID = id
        lastError = nil
        goalProposals = []
        Task { await refreshGoalProposals() }
    }

    /// A blank conversation, with Marcel or with an assistant (`assistantID`), as many as wanted.
    func newConversation(in projectID: UUID? = nil, assistant assistantID: String? = nil) {
        if conversation.messages.isEmpty {
            // Reuse the blank conversation instead of stacking empty ones.
            mutate(currentID) {
                $0.projectID = projectID
                $0.assistantID = assistantID
            }
        } else {
            let fresh = Conversation(projectID: projectID, assistantID: assistantID)
            conversations.append(fresh)
            currentID = fresh.id
            lastError = nil
            goalProposals = []
        }
        if assistantID != nil { Task { await refreshAssistants() } }
    }

    /// Opens a bot's conversation, the one that continues (its row in the menu).
    func openBot(_ assistantID: String?) {
        if conversation.assistantID == assistantID, !conversation.isPrivate, !isPastConversation { return }
        if let thread = thread(ofBot: assistantID) {
            select(thread.id)
        } else {
            newConversation(assistant: assistantID)
        }
    }

    // MARK: - One conversation per bot (like Grok Bot)

    /// A bot's conversation: its latest one, which continues from one day to the next.
    func thread(ofBot assistantID: String?) -> Conversation? {
        listedConversations.first { $0.assistantID == assistantID }
    }

    /// A bot's earlier conversations, put aside by « Repartir de zéro », newest first.
    func history(ofBot assistantID: String?) -> [Conversation] {
        let all = listedConversations.filter { $0.assistantID == assistantID }
        // Just after « Repartir de zéro », the blank conversation is the one that continues.
        let fresh = conversation.messages.isEmpty && !conversation.isPrivate && conversation.assistantID == assistantID
        return fresh ? all : Array(all.dropFirst())
    }

    /// The open conversation is an earlier one of its bot, read from its history.
    var isPastConversation: Bool {
        !conversation.isPrivate && !conversation.messages.isEmpty
            && thread(ofBot: conversation.assistantID)?.id != conversation.id
    }

    /// « Repartir de zéro »: the bot's conversation goes to its history, a blank one takes its place.
    func startFresh() {
        guard !conversation.isPrivate, !conversation.messages.isEmpty, !isStreaming else { return }
        newConversation(assistant: conversation.assistantID)
    }

    /// The last thing said in a bot's latest conversation, for its row in the menu.
    func lastLine(ofBot assistantID: String?) -> String? {
        listedConversations.first { $0.assistantID == assistantID }?.messages.last
            .map { message in
                // Plain text: no Markdown marks in a one-line preview.
                message.content.filter { !"*#`>_".contains($0) }
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }
    }

    /// A web search a bot asked for, validated: sent as the user's message with the exact question,
    /// which the server checks again and searches with code that knows nothing else.
    private func approveSearch(_ action: MissionAction, in messageID: UUID) {
        guard let question = action.query, !question.isEmpty, !isStreaming,
              let conversation = conversations.first(where: { $0.messages.contains { $0.id == messageID } }),
              conversation.id == currentID else {
            report("Ouvre la conversation du bot et attends qu'il ait fini pour valider la recherche.", action: nil)
            return
        }
        updateMessage(messageID, in: conversation.id) { message in
            if let index = message.actions.firstIndex(where: { $0.id == action.id }) {
                message.actions[index].status = "done"
                message.actions[index].detail = "« \(question) » : validée"
            }
        }
        pendingSearch = question
        sendSuggestion("Cherche : « \(question) »")
    }

    /// A suggestion touched (on the welcome or under a reply): sent at once as the user's message.
    /// What was waiting in the composer stays there.
    func sendSuggestion(_ text: String) {
        guard !isStreaming, !emergencyActive else { return }
        let previousDraft = draft
        let previousAttachments = pendingAttachments
        draft = text
        pendingAttachments = []
        send()
        draft = previousDraft
        pendingAttachments = previousAttachments
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate(id) { $0.title = trimmed }
        persist(id, touch: false)
    }

    func move(_ id: UUID, to projectID: UUID?) {
        mutate(id) { $0.projectID = projectID }
        persist(id, touch: false)
    }

    func setMood(_ id: UUID, _ mood: MarcelMood?) {
        mutate(id) { $0.mood = mood }
        persist(id, touch: false)
    }

    func delete(_ id: UUID) {
        streamTasks[id]?.cancel()
        if let conversation = conversations.first(where: { $0.id == id }) {
            AttachmentStore.delete(conversation.messages.flatMap(\.attachments))
        }
        conversations.removeAll { $0.id == id }
        cache.delete(id)
        if id == currentID {
            if let next = listedConversations.first {
                currentID = next.id
            } else {
                let fresh = Conversation()
                conversations.append(fresh)
                currentID = fresh.id
            }
        }
    }

    // MARK: - Projects

    @discardableResult
    func createProject(named name: String) -> Project? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let project = Project(name: trimmed)
        projects.append(project)
        cache.saveProjects(projects)
        return project
    }

    func renameProject(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].name = trimmed
        cache.saveProjects(projects)
    }

    /// Deletes the project only; its conversations go back to the general list.
    func deleteProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        cache.saveProjects(projects)
        for conversation in conversations where conversation.projectID == id {
            move(conversation.id, to: nil)
        }
    }

    // MARK: - Attachments

    func addImage(_ data: Data) async {
        await prepareAttachment { try await AttachmentStore.storeImage(data) }
    }

    func addFile(at url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        await prepareAttachment { try await AttachmentStore.storeFile(at: url) }
    }

    func removePending(_ attachment: Attachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
        AttachmentStore.delete([attachment])
    }

    private func prepareAttachment(_ work: () async throws -> Attachment) async {
        isPreparingAttachment = true
        defer { isPreparingAttachment = false }
        do {
            pendingAttachments.append(try await work())
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Server

    func checkServer() async {
        guard !emergencyActive else { return }
        guard let api = settings.api else {
            serverStatus = .unreachable
            return
        }
        if serverStatus != .reachable { serverStatus = .checking }
        let health = await api.health()
        switch health?.status {
        case 200:
            serverStatus = .reachable
            unseenIdeas = health?.unseenIdeas ?? 0
            tokenUsage = health?.tokens
            Task { await syncPlanning() }
            if health?.emergency == true {
                // Stopped from elsewhere (another device, curl): honour it here too.
                applyEmergencyLocally()
                return
            }
            if models.isEmpty, let loaded = try? await api.models() { models = loaded }
            if assistants.isEmpty { await refreshAssistants() }
            resumeMissions()
            await refreshGoalProposals()
            await importRoutineRuns()
            await importBotMessages()
        case 401, 403: serverStatus = .unauthorized
        default: serverStatus = .unreachable
        }
    }

    func useServer(_ profile: ServerProfile) {
        guard profile.id != settings.activeID else { return }
        settings.activeID = profile.id
        models = []
        assistants = []
        goalProposals = []
        unseenIdeas = 0
        tokenUsage = nil
        serverStatus = .checking
        Task { await checkServer() }
    }

    // MARK: - Models

    var selectedModel: ModelOption? {
        models.first { $0.id == modelChoice[settings.activeID.uuidString] } ?? models.first
    }

    func selectModel(_ model: ModelOption) {
        modelChoice[settings.activeID.uuidString] = model.id
    }

    func label(forModel id: String?) -> String? {
        guard let id else { return nil }
        return models.first { $0.id == id }?.label ?? id
    }

    // MARK: - Goals

    func refreshGoalProposals() async {
        guard !emergencyActive, let api = settings.api else { return }
        let id = currentID
        guard let found = try? await api.goals(status: "proposed", conversationID: id) else { return }
        if id == currentID { goalProposals = found }
    }

    /// Follows the goal Marcel proposed, or declines it (it won't be proposed again).
    func answer(_ proposal: Goal, follow: Bool) async {
        goalProposals.removeAll { $0.id == proposal.id }
        guard !emergencyActive, let api = settings.api else { return }
        do {
            _ = try await api.updateGoal(id: proposal.id, GoalChange(status: follow ? "active" : "dismissed"))
        } catch {
            lastError = error.localizedDescription
            await refreshGoalProposals()
        }
    }

    /// The server looks for goals once the reply is complete, in the background: check a few times.
    private func refreshGoalProposalsAfterReply() {
        Task {
            for wait in [1.5, 6, 20] {
                try? await Task.sleep(for: .seconds(wait))
                await refreshGoalProposals()
                if !goalProposals.isEmpty { return }
            }
        }
    }

    // MARK: - Errors and settings

    func openSettings(_ route: SettingsRoute) {
        settingsRequest = route
    }

    func perform(_ action: ErrorAction) {
        lastError = nil
        switch action {
        case .openSettings(let route, _):
            openSettings(route)
        case .retry:
            if canRegenerate, conversation.messages.last?.status == .failed {
                regenerate()
            } else {
                Task { await checkServer() }
            }
        }
    }

    private func report(_ message: String, action: ErrorAction?) {
        lastError = message
        lastErrorAction = action
    }

    /// The way out of an error: the right settings screen, or trying again.
    private func action(for error: Error) -> ErrorAction? {
        switch error {
        case MarcelAPIError.unauthorized:
            .openSettings(.server(settings.activeID), label: "Vérifier le jeton")
        case MarcelAPIError.notConfigured:
            .openSettings(.server(settings.activeID), label: "Régler le serveur")
        case MarcelAPIError.http(429, let body) where body.contains("Budget"):
            .openSettings(.proactive, label: "Voir la consommation")
        case is URLError:
            .retry
        default:
            nil
        }
    }

    /// Asks the server for the badge and token counters again, without the rest of a health check.
    func refreshCounters() async {
        guard !emergencyActive, let api = settings.api, let health = await api.health(), health.status == 200 else { return }
        unseenIdeas = health.unseenIdeas
        tokenUsage = health.tokens
    }

    /// Fetches the work planning, then schedules the clock-in reminders and fills the "Missions
    /// RMA" calendar, at most every 10 minutes (the health check runs every 30 s) unless `force`.
    func syncPlanning(force: Bool = false) async {
        guard WorkReminders.isEnabled || MissionCalendar.isEnabled, !emergencyActive, let api = settings.api else { return }
        if !force, let last = lastPlanningSync, Date.now.timeIntervalSince(last) < 600 { return }
        lastPlanningSync = .now
        guard let missions = try? await api.planning(days: 60) else { return }
        planningMissions = missions
        await WorkReminders.schedule(missions)
        MissionCalendar.sync(missions)
    }

    // MARK: - Assistants

    /// Illustrations the user picked for assistants, kept here too so the choice shows at once
    /// (and even with a server not updated yet).
    private var assistantMoods: [String: String] = UserDefaults.standard.dictionary(forKey: "assistantMoods") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(assistantMoods, forKey: "assistantMoods") }
    }

    func mood(for assistant: Assistant) -> MarcelMood {
        assistantMoods[assistant.id].flatMap(MarcelMood.init(rawValue:)) ?? assistant.displayMood
    }

    func setMood(_ mood: MarcelMood, for assistant: Assistant) async {
        assistantMoods[assistant.id] = mood.rawValue
        guard !emergencyActive, let api = settings.api else { return }
        if let updated = try? await api.updateAssistant(id: assistant.id, changes: [:], mood: mood.rawValue) {
            replace(updated)
        }
    }

    func assistant(for conversation: Conversation) -> Assistant? {
        conversation.assistantID.flatMap { id in assistants.first { $0.id == id } }
    }

    /// What a bot may read, switched on or off in its card.
    func setRead(_ key: String, _ on: Bool, of assistant: Assistant) async {
        guard !emergencyActive, let api = settings.api else { return }
        var reads = Set((assistant.reads ?? []).filter(\.on).map(\.key))
        if on { reads.insert(key) } else { reads.remove(key) }
        do {
            replace(try await api.updateAssistant(id: assistant.id, changes: [:], reads: reads.sorted()))
        } catch {
            report("Lecture non changée : \(error.localizedDescription)", action: action(for: error))
        }
    }

    /// A setting changed by hand in the Assistants screen: checked and saved by the server.
    func updateSetting(_ key: String, to value: SettingValue, of assistant: Assistant) async {
        guard !emergencyActive, let api = settings.api else { return }
        do {
            replace(try await api.updateAssistant(id: assistant.id, changes: [key: value]))
            if assistant.id == "planning" { await syncPlanning(force: true) }
        } catch {
            report("Réglage non appliqué : \(error.localizedDescription)", action: action(for: error))
        }
    }

    /// Fetches the assistants, then applies Pointage's settings to the reminders on this iPhone.
    func refreshAssistants() async {
        guard !emergencyActive, let api = settings.api else { return }
        // The three at once rather than one after the other.
        async let loadedAssistants = try? api.assistants()
        async let loadedOffers = try? api.offers()
        async let loadedMissions = try? api.planning(days: 60)
        guard let loaded = await loadedAssistants else { return }
        assistants = loaded
        applyLocalSettings()
        if let list = await loadedOffers { offers = list.offers }
        if let missions = await loadedMissions { planningMissions = missions }
    }

    /// The user confirmed ("Oui") accepting or refusing an offer: the robot answers in the portal.
    func answer(_ offer: Offer, accept: Bool) async {
        guard !emergencyActive, let api = settings.api else { return }
        do {
            try await api.answerOffer(id: offer.id, accept: accept)
        } catch {
            report("Réponse non envoyée : \(error.localizedDescription)", action: action(for: error))
        }
        await refreshAssistants()
    }

    func cancelAnswer(_ offer: Offer) async {
        guard !emergencyActive, let api = settings.api else { return }
        try? await api.cancelOfferAnswer(id: offer.id)
        await refreshAssistants()
    }

    /// Pointage's settings are carried out by the iPhone: reminders are scheduled again when they change.
    private func applyLocalSettings() {
        guard let pointage = assistants.first(where: { $0.id == "pointage" }) else { return }
        if WorkReminders.apply(pointage) { Task { await syncPlanning(force: true) } }
    }

    private func replace(_ assistant: Assistant) {
        if let index = assistants.firstIndex(where: { $0.id == assistant.id }) {
            assistants[index] = assistant
        } else {
            assistants.append(assistant)
        }
        applyLocalSettings()
    }

    /// The user tapped "Appliquer" under a proposal: the server checks and saves it.
    func applyProposal(_ messageID: UUID) async {
        guard let conversation = conversations.first(where: { $0.messages.contains { $0.id == messageID } }),
              let reply = message(messageID, in: conversation.id),
              let proposal = AssistantProposal.split(AssistantDraft.split(reply.content).text).proposal,
              // Marcel names the assistant; in an assistant's own conversation, it's that one.
              let assistantID = proposal.assistant ?? conversation.assistantID else { return }
        guard !emergencyActive, let api = settings.api else {
            report(MarcelAPIError.notConfigured.localizedDescription, action: action(for: MarcelAPIError.notConfigured))
            return
        }
        let instruction = proposal.consigne.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let updated = try await api.updateAssistant(id: assistantID, changes: proposal.changes,
                                                        instruction: instruction.isEmpty ? nil : instruction,
                                                        actions: proposal.actions)
            replace(updated)
            updateMessage(messageID, in: conversation.id) { $0.proposalDecision = "applied" }
            persist(conversation.id, touch: false)
            if assistantID == "planning" { await syncPlanning(force: true) }
        } catch {
            report("Réglage non appliqué : \(error.localizedDescription)", action: action(for: error))
        }
    }

    func cancelProposal(_ messageID: UUID) {
        guard let conversation = conversations.first(where: { $0.messages.contains { $0.id == messageID } }) else { return }
        updateMessage(messageID, in: conversation.id) { $0.proposalDecision = "cancelled" }
        persist(conversation.id, touch: false)
    }

    func deleteInstruction(_ instruction: Assistant.Instruction, of assistant: Assistant) async {
        guard !emergencyActive, let api = settings.api else { return }
        do {
            replace(try await api.deleteInstruction(assistantID: assistant.id, id: instruction.id))
        } catch {
            report("Consigne non retirée : \(error.localizedDescription)", action: action(for: error))
        }
    }

    // MARK: - A bot's standing task, taught tasks and shared skills

    /// Sets (or changes) what the bot does alone. Its results come back in its latest conversation.
    func setTask(_ change: BotTaskChange, of assistant: Assistant) async -> Bool {
        guard !emergencyActive, let api = settings.api else { return false }
        var change = change
        if change.conversationID.isEmpty {
            change.conversationID = listedConversations.first { $0.assistantID == assistant.id && $0.projectID == nil }?
                .id.uuidString ?? ""
        }
        do {
            replace(try await api.setTask(assistantID: assistant.id, change))
            return true
        } catch {
            report("Tâche non enregistrée : \(error.localizedDescription)", action: action(for: error))
            return false
        }
    }

    func deleteTask(of assistant: Assistant) async {
        guard !emergencyActive, let api = settings.api else { return }
        do {
            replace(try await api.deleteTask(assistantID: assistant.id))
        } catch {
            report("Tâche non retirée : \(error.localizedDescription)", action: action(for: error))
        }
    }

    /// Runs the standing task now, to try it; its result arrives like a routine's.
    func runTask(of assistant: Assistant) async {
        guard !emergencyActive, let api = settings.api else { return }
        do {
            try await api.runTask(assistantID: assistant.id)
        } catch {
            report("Tâche non lancée : \(error.localizedDescription)", action: action(for: error))
        }
    }

    func updateRecipe(_ recipe: Assistant.Recipe, title: String, steps: [String], of assistant: Assistant) async -> Bool {
        guard !emergencyActive, let api = settings.api else { return false }
        do {
            replace(try await api.updateRecipe(assistantID: assistant.id, id: recipe.id, title: title, steps: steps))
            return true
        } catch {
            report("Tâche non modifiée : \(error.localizedDescription)", action: action(for: error))
            return false
        }
    }

    func deleteRecipe(_ recipe: Assistant.Recipe, of assistant: Assistant) async {
        guard !emergencyActive, let api = settings.api else { return }
        do {
            replace(try await api.deleteRecipe(assistantID: assistant.id, id: recipe.id))
        } catch {
            report("Tâche non effacée : \(error.localizedDescription)", action: action(for: error))
        }
    }

    /// A shared skill ticked or not for this bot.
    func setSkill(_ id: String, _ on: Bool, of assistant: Assistant) async {
        guard !emergencyActive, let api = settings.api else { return }
        var chosen = (assistant.skills ?? []).filter(\.on).map(\.id)
        if on { chosen.append(id) } else { chosen.removeAll { $0 == id } }
        do {
            replace(try await api.updateAssistant(id: assistant.id, changes: [:], skills: chosen))
        } catch {
            report("Skill non changée : \(error.localizedDescription)", action: action(for: error))
        }
    }

    /// The user tapped "Créer l'assistant" under Marcel's proposal: created, then opened.
    func createAssistant(_ draft: AssistantDraft, from messageID: UUID) async {
        guard !emergencyActive, let api = settings.api else { return }
        let conversationID = currentID
        do {
            let created = try await api.createAssistant(draft)
            replace(created)
            updateMessage(messageID, in: conversationID) { $0.proposalDecision = "applied" }
            persist(conversationID, touch: false)
            openBot(created.id)
        } catch {
            report("Assistant non créé : \(error.localizedDescription)", action: action(for: error))
        }
    }

    /// Deletes an assistant the user made; its conversations stay, back with Marcel.
    func deleteAssistant(_ assistant: Assistant) async {
        guard assistant.isCustom, !emergencyActive, let api = settings.api else { return }
        do {
            try await api.deleteAssistant(id: assistant.id)
            assistants.removeAll { $0.id == assistant.id }
            for conversation in conversations where conversation.assistantID == assistant.id {
                mutate(conversation.id) { $0.assistantID = nil }
                persist(conversation.id, touch: false)
            }
        } catch {
            report("Assistant non supprimé : \(error.localizedDescription)", action: action(for: error))
        }
    }

    /// The user approved what waited under an "ask first" rule: the server does it now.
    func approve(_ action: MissionAction, in messageID: UUID) async {
        if action.isSearch {
            return approveSearch(action, in: messageID)
        }
        if action.isIPhone {
            return await runOnIPhone(action, in: messageID)
        }
        guard !emergencyActive,
              let conversation = conversations.first(where: { $0.messages.contains { $0.id == messageID } }),
              let reply = message(messageID, in: conversation.id), let missionID = reply.missionID,
              let api = api(forServer: reply.serverID) else { return }
        do {
            let card = try await api.approve(card: action.id, missionID: missionID)
            updateMessage(messageID, in: conversation.id) { message in
                if let index = message.actions.firstIndex(where: { $0.id == action.id }) { message.actions[index] = card }
            }
            persist(conversation.id, touch: false)
        } catch {
            report("Pas validé : \(error.localizedDescription)", action: self.action(for: error))
        }
    }

    /// « Toujours autoriser », like Grok Bot's "Always allow": this kind of action goes to "Tout
    /// seul" in Réglages › Règles, then this one is done now. The fixed limits stay whatever the rule.
    /// « Toujours »: for this bot only (Grok Bot's "Always allow for this Bot"), or everywhere.
    func approveAlways(_ action: MissionAction, in messageID: UUID, onlyThisBot: Bool = false) async {
        guard let kind = action.ruleKind, !emergencyActive, let api = settings.api else { return }
        do {
            _ = try await api.setRules([kind: "auto"], assistant: onlyThisBot ? bot(of: messageID) : nil)
        } catch {
            return report("Règle non changée : \(error.localizedDescription)", action: self.action(for: error))
        }
        await approve(action, in: messageID)
    }

    /// « Toujours autoriser » on a change of settings proposed by a bot: the rule, then « Appliquer ».
    func applyProposalAlways(_ messageID: UUID, onlyThisBot: Bool = false) async {
        guard !emergencyActive, let api = settings.api else { return }
        do {
            _ = try await api.setRules(["reglage": "auto"], assistant: onlyThisBot ? bot(of: messageID) : nil)
        } catch {
            return report("Règle non changée : \(error.localizedDescription)", action: self.action(for: error))
        }
        await applyProposal(messageID)
    }

    /// The bot whose conversation holds this message; nil for Marcel's.
    func bot(of messageID: UUID) -> String? {
        conversations.first { $0.messages.contains { $0.id == messageID } }?.assistantID
    }

    /// « Refuser »: what waited is left undone, and the card says so.
    func decline(_ action: MissionAction, in messageID: UUID) {
        guard let conversation = conversations.first(where: { $0.messages.contains { $0.id == messageID } }) else { return }
        updateMessage(messageID, in: conversation.id) { $0.declined.append(action.id) }
        persist(conversation.id, touch: false)
    }

    /// The user took back what Marcel did himself at the end of a reply ("Annuler" on its result).
    func undo(_ action: MissionAction, in messageID: UUID) async {
        guard let undo = action.undo, !emergencyActive,
              let conversation = conversations.first(where: { $0.messages.contains { $0.id == messageID } }),
              let api = api(forServer: message(messageID, in: conversation.id)?.serverID) else { return }
        do {
            switch undo.kind {
            case "reglage":
                guard let assistantID = undo.assistant else { return }
                if !(undo.changes ?? [:]).isEmpty || undo.mood != nil {
                    replace(try await api.updateAssistant(id: assistantID, changes: undo.changes ?? [:], mood: undo.mood))
                }
                if let note = undo.instruction {
                    replace(try await api.deleteInstruction(assistantID: assistantID, id: note))
                }
                if assistantID == "planning" { await syncPlanning(force: true) }
            case "assistant":
                guard let id = undo.id else { return }
                if let created = assistants.first(where: { $0.id == id }) {
                    await deleteAssistant(created)
                } else {
                    try await api.deleteAssistant(id: id)
                }
            case "objectif":
                guard let id = undo.id else { return }
                _ = try await api.updateGoal(id: id, GoalChange(status: "dismissed"))
            case "routine":
                guard let id = undo.id else { return }
                try await api.deleteRoutine(id: id)
            case "recette":
                guard let id = undo.id, let assistantID = undo.assistant else { return }
                replace(try await api.deleteRecipe(assistantID: assistantID, id: id))
            default:
                return
            }
            updateMessage(messageID, in: conversation.id) { $0.undone.append(action.id) }
            persist(conversation.id, touch: false)
        } catch {
            report("Pas annulé : \(error.localizedDescription)", action: self.action(for: error))
        }
    }

    // MARK: - Code requests

    /// The user tapped "Envoyer à Claude Code" (or Codex) under Marcel's request: GitHub gets the issue.
    func sendCodeRequest(from messageID: UUID) async -> CodeRequest? {
        guard let conversation = conversations.first(where: { $0.messages.contains { $0.id == messageID } }),
              let reply = message(messageID, in: conversation.id), let missionID = reply.missionID,
              !emergencyActive, let api = api(forServer: reply.serverID) else { return nil }
        do {
            let sent = try await api.sendCodeRequest(missionID: missionID)
            updateMessage(messageID, in: conversation.id) { $0.proposalDecision = "applied" }
            persist(conversation.id, touch: false)
            return sent
        } catch {
            report("Demande non envoyée : \(error.localizedDescription)", action: action(for: error))
            return nil
        }
    }

    // MARK: - Routines

    /// Puts the replies of routines that ran on the server in their own conversation (one per
    /// routine, which the user can answer like any other).
    func importRoutineRuns() async {
        guard !emergencyActive, let api = settings.api, let runs = try? await api.pendingRoutineRuns() else { return }
        for run in runs {
            guard let rawID = run.conversationID, let id = UUID(uuidString: rawID) else { continue }
            // A reply is being written there: the routine's comes after it, next time.
            guard !isStreaming(id) else { continue }
            let content = run.status == "done"
                ? (run.text ?? "")
                : "La routine « \(run.title ?? "") » n'a pas pu aboutir : \(run.error.isEmpty ? "erreur inconnue" : run.error)."
            var reply = ChatMessage(role: .assistant, content: content, createdAt: run.at, serverID: settings.activeID,
                                    model: run.model)
            reply.missionID = run.missionID
            reply.actions = run.actions ?? []
            if conversations.contains(where: { $0.id == id }) {
                mutate(id) { conversation in
                    guard !conversation.messages.contains(where: { $0.missionID == run.missionID }) else { return }
                    conversation.messages.append(reply)
                }
            } else {
                let assistantID = run.assistant.flatMap { $0.isEmpty ? nil : $0 }
                conversations.append(Conversation(id: id, title: run.title ?? "Routine", messages: [reply],
                                                  assistantID: assistantID))
            }
            persist(id)
            try? await api.markRoutineRunDelivered(id: run.id)
        }
    }

    /// Puts what the user said to a bot on Telegram, and its reply, in that bot's conversation.
    func importBotMessages() async {
        guard !emergencyActive, let api = settings.api, let entries = try? await api.pendingBotMessages() else { return }
        for entry in entries {
            guard let id = UUID(uuidString: entry.conversationID), !isStreaming(id) else { continue }
            var question = ChatMessage(role: .user, content: entry.question, createdAt: entry.at, serverID: settings.activeID)
            question.via = entry.via
            var reply = ChatMessage(role: .assistant, content: entry.status == "done" ? entry.text
                                    : "Pas de réponse sur \(entry.via) (\(entry.status)).",
                                    createdAt: entry.at.addingTimeInterval(1), serverID: settings.activeID, model: entry.model)
            reply.missionID = entry.missionID
            reply.actions = entry.actions ?? []
            if conversations.contains(where: { $0.id == id }) {
                mutate(id) { conversation in
                    guard !conversation.messages.contains(where: { $0.missionID == entry.missionID }) else { return }
                    conversation.messages += [question, reply]
                }
            } else {
                conversations.append(Conversation(id: id, title: "\(entry.assistantName) · \(entry.via)",
                                                  messages: [question, reply], assistantID: entry.assistant))
            }
            persist(id)
            try? await api.markBotMessageDelivered(id: entry.id)
        }
    }

    // MARK: - Ideas

    func markIdeasSeen() async {
        guard !emergencyActive, let api = settings.api else { return }
        if (try? await api.markIdeasSeen()) != nil { unseenIdeas = 0 }
    }

    /// Opens the conversation an idea became, or starts one with Marcel's message.
    /// A prepared action is only put in the composer: nothing happens until the user sends it.
    func open(_ idea: Idea, prefillAction: Bool = true) async {
        if let id = UUID(uuidString: idea.conversationID), conversations.contains(where: { $0.id == id }) {
            select(id)
            return
        }
        var text = "**\(idea.title)**\n\n\(idea.body)"
        if !idea.action.isEmpty {
            text += "\n\n> Action préparée : \(idea.action)\n> Rien n'est fait sans ton accord : envoie « Vas-y » pour la lancer."
        }
        let fresh = Conversation(title: String(idea.title.prefix(60)),
                                 messages: [ChatMessage(role: .assistant, content: text, serverID: settings.activeID)])
        dropCurrentIfEmpty()
        conversations.append(fresh)
        currentID = fresh.id
        lastError = nil
        goalProposals = []
        persist(fresh.id)
        if prefillAction, !idea.action.isEmpty, draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = "Vas-y : \(idea.action)"
        }
        guard !emergencyActive, let api = settings.api else { return }
        _ = try? await api.updateIdea(id: idea.id, status: "opened", conversationID: fresh.id)
    }

    /// The user approved the action shown in the preview: it is sent as their message in the
    /// idea's conversation, with the exact content, and Marcel (the full Hermes) carries it out.
    func approve(_ idea: Idea) async {
        guard !emergencyActive, !idea.action.isEmpty else { return }
        await open(idea, prefillAction: false)
        var message = "Je valide l'action préparée : \(idea.action)"
        if let detail = idea.actionDetail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            message += "\n\nFais exactement ceci, rien de plus :\n\(detail)"
            message += "\n\nSi quelque chose a changé (prix, disponibilité, destinataire), ne fais rien et explique-moi."
        } else {
            message += "\n\nMontre-moi d'abord le texte exact et attends mon accord avant d'envoyer quoi que ce soit."
        }
        guard !isStreaming else {
            report("Marcel répond encore dans cette conversation : valide à nouveau quand il a fini.", action: nil)
            return
        }
        // What was waiting in the composer stays there and doesn't leave with the approval.
        let previousDraft = draft
        let previousAttachments = pendingAttachments
        draft = message
        pendingAttachments = []
        send()
        draft = previousDraft
        pendingAttachments = previousAttachments
        guard let api = settings.api else { return }
        _ = try? await api.updateIdea(id: idea.id, status: "approved", conversationID: currentID)
    }

    // MARK: - Emergency stop

    /// Cuts everything: local streams, and every mission on the servers that may be working for us.
    func emergencyStop() {
        var servers = [settings.activeID]
        for conversation in conversations {
            if let reply = conversation.messages.last, reply.status == .streaming, let id = reply.serverID {
                servers.append(id)
            }
        }
        let targets = Set(servers).compactMap { id in settings.profiles.first { $0.id == id } }.compactMap(settings.api(for:))
        applyEmergencyLocally()
        Task {
            var failures = 0
            for api in targets {
                do { try await api.setEmergency(true) } catch { failures += 1 }
            }
            if failures > 0 {
                lastError = "Arrêt local fait, mais \(failures == 1 ? "un serveur n'a" : "\(failures) serveurs n'ont") pas confirmé l'arrêt."
            }
        }
    }

    func emergencyResume() async {
        emergencyActive = false
        lastError = nil
        if let api = settings.api {
            do { try await api.setEmergency(false) } catch {
                lastError = "Reprise locale faite, mais le serveur n'a pas confirmé : \(error.localizedDescription)"
            }
        }
        await checkServer()
    }

    private func applyEmergencyLocally() {
        emergencyActive = true
        goalProposals = []
        unseenIdeas = 0
        for task in streamTasks.values { task.cancel() }
        streamTasks = [:]
        for conversation in conversations {
            guard let reply = conversation.messages.last, reply.status == .streaming else { continue }
            updateMessage(reply.id, in: conversation.id) { $0.status = .stopped }
            persist(conversation.id, touch: false)
        }
    }

    // MARK: - Missions

    func serverMissions() async throws -> [MissionInfo] {
        guard let api = settings.api else { throw MarcelAPIError.notConfigured }
        return try await api.missions()
    }

    func cancelMission(id: String) async {
        guard let api = settings.api else { return }
        do { try await api.cancelMission(id: id) } catch { lastError = error.localizedDescription }
    }

    /// Opens the local conversation a server mission belongs to, if it's on this iPhone.
    @discardableResult
    func openConversation(forMission mission: MissionInfo) -> Bool {
        guard let id = UUID(uuidString: mission.conversationID), conversations.contains(where: { $0.id == id }) else {
            return false
        }
        select(id)
        return true
    }

    func send() {
        // "/planning …": the mode changes, then the rest is sent (nothing when it was only that).
        if !isStreaming, applySlashMode(), draft.isEmpty, pendingAttachments.isEmpty { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard canSend else { return }
        guard let api = settings.api else {
            report(MarcelAPIError.notConfigured.localizedDescription, action: action(for: MarcelAPIError.notConfigured))
            return
        }

        let id = currentID
        lastError = nil
        draft = ""
        pendingAttachments = []
        let userMessage = ChatMessage(role: .user, content: text, attachments: attachments)
        mutate(id) { conversation in
            if conversation.messages.isEmpty {
                conversation.title = String((text.isEmpty ? attachments.first?.filename ?? "Pièce jointe" : text).prefix(60))
            }
            conversation.messages.append(userMessage)
        }
        startReply(in: id, after: userMessage.id, using: api)
    }

    /// Adds an empty reply and starts its mission (after uploading the user message's attachments).
    private func startReply(in id: UUID, after userMessageID: UUID, using api: MarcelAPI) {
        let model = selectedModel?.id
        let reply = ChatMessage(role: .assistant, content: "", status: .streaming, serverID: settings.activeID, model: model)
        mutate(id) { $0.messages.append(reply) }
        persist(id)

        let search = pendingSearch ?? ""
        pendingSearch = nil
        streamTasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.uploadAttachments(of: userMessageID, in: id, using: api)
                let history = self.conversations.first { $0.id == id }?.messages.filter { $0.status == .complete } ?? []
                let assistantID = self.conversations.first { $0.id == id }?.assistantID
                let isPrivate = self.conversations.first { $0.id == id }?.isPrivate ?? false
                let mission = try await api.startMission(conversationID: id, messages: history, model: model,
                                                         deviceContext: isPrivate ? nil : Agenda.upcoming(),
                                                         assistant: assistantID, isPrivate: isPrivate,
                                                         style: UserDefaults.standard.string(forKey: Self.replyStyleKey) ?? "",
                                                         search: search)
                self.updateMessage(reply.id, in: id) { message in
                    message.missionID = mission.id
                    // "Auto" becomes the model the server picked for this message.
                    if let used = mission.model { message.model = used }
                }
                self.persist(id)
            } catch {
                if Task.isCancelled {
                    self.finish(reply.id, in: id, .stopped)
                } else {
                    self.finish(reply.id, in: id, .failed, error: "Envoi impossible : \(error.localizedDescription)",
                                action: self.action(for: error))
                    if error is URLError { self.serverStatus = .unreachable }
                }
                self.streamTasks[id] = nil
                self.persist(id)
                return
            }
            await self.follow(reply.id, in: id)
        }
    }

    /// The last reply can be written again when it's finished and follows a message of the user.
    var canRegenerate: Bool {
        let messages = conversation.messages
        return !isStreaming && !emergencyActive && messages.count >= 2
            && messages.last?.role == .assistant && messages[messages.count - 2].role == .user
    }

    func regenerate() {
        guard canRegenerate, let api = settings.api else { return }
        let id = currentID
        let messages = conversation.messages
        let userMessageID = messages[messages.count - 2].id
        lastError = nil
        mutate(id) { _ = $0.messages.removeLast() }
        startReply(in: id, after: userMessageID, using: api)
    }

    /// Puts a message of the user back in the composer and removes it with everything after it.
    func edit(_ messageID: UUID) {
        guard !isStreaming, let index = conversation.messages.firstIndex(where: { $0.id == messageID }),
              conversation.messages[index].role == .user else { return }
        let message = conversation.messages[index]
        draft = message.content
        pendingAttachments = message.attachments
        mutate(currentID) { $0.messages.removeSubrange(index...) }
        persist(currentID)
    }

    /// Uploads attachments not yet on the server and records their remote ids.
    private func uploadAttachments(of messageID: UUID, in conversationID: UUID, using api: MarcelAPI) async throws {
        let message = conversations.first { $0.id == conversationID }?.messages.first { $0.id == messageID }
        for attachment in message?.attachments ?? [] where attachment.remoteID == nil {
            let data = try AttachmentStore.data(for: attachment)
            let remoteID = try await api.upload(attachment, data: data)
            updateMessage(messageID, in: conversationID) { message in
                if let index = message.attachments.firstIndex(where: { $0.id == attachment.id }) {
                    message.attachments[index].remoteID = remoteID
                }
            }
        }
    }

    /// Stops the mission on the server; the reply keeps what was written so far.
    func stop() {
        let id = currentID
        guard let reply = conversation.messages.last, reply.status == .streaming else { return }
        guard let missionID = reply.missionID, let api = api(forServer: reply.serverID) else {
            // Still uploading: nothing runs on the server yet.
            streamTasks[id]?.cancel()
            return
        }
        Task {
            do {
                try await api.cancelMission(id: missionID)
                // The following task, if any, receives "stopped"; otherwise settle it here.
                if streamTasks[id] == nil { finish(reply.id, in: id, .stopped) }
            } catch {
                if id == currentID { lastError = "Impossible d'arrêter la mission : \(error.localizedDescription)" }
            }
        }
    }

    /// Follows every reply still being generated on a server, e.g. after the app was closed.
    func resumeMissions() {
        guard !emergencyActive else { return }
        for conversation in conversations where streamTasks[conversation.id] == nil {
            guard let reply = conversation.messages.last, reply.status == .streaming, reply.missionID != nil else { continue }
            let id = conversation.id
            streamTasks[id] = Task { [weak self] in await self?.follow(reply.id, in: id) }
        }
    }

    /// Streams a mission's text into the reply, reconnecting from where it left off until it ends.
    private func follow(_ replyID: UUID, in conversationID: UUID) async {
        var delay = Duration.seconds(1)
        // Text arrives a few characters at a time; redrawing (and re-parsing the Markdown of) the
        // whole reply for each piece is wasted work, so pieces are applied at most every 80 ms.
        var pending = ""
        var lastFlush = ContinuousClock.now
        func flush() {
            guard !pending.isEmpty else { return }
            let chunk = pending
            pending = ""
            lastFlush = .now
            updateMessage(replyID, in: conversationID) { $0.content += chunk }
        }
        while !Task.isCancelled {
            guard let reply = message(replyID, in: conversationID), reply.status == .streaming,
                  let missionID = reply.missionID else { break }
            guard let api = api(forServer: reply.serverID) else {
                finish(replyID, in: conversationID, .failed, error: "Le serveur de cette mission n'est plus dans les réglages.")
                break
            }
            do {
                // Pending text must be applied before reconnecting: the offset is read from the reply.
                defer { flush() }
                let offset = reply.content.unicodeScalars.count
                for try await event in api.missionEvents(id: missionID, offset: offset) {
                    serverStatus = .reachable
                    delay = .seconds(1)
                    if case .delta(let text) = event {
                        pending += text
                        if ContinuousClock.now - lastFlush >= .milliseconds(80) { flush() }
                        continue
                    }
                    flush()
                    switch event {
                    case .actions(let actions): updateMessage(replyID, in: conversationID) { $0.actions = actions }
                    case .delta: break
                    case .done:
                        finish(replyID, in: conversationID, .complete)
                        Task { await self.iPhoneAsked(replyID, in: conversationID) }
                        if conversationID == currentID, UserDefaults.standard.bool(forKey: Speaker.autoReadKey),
                           let finished = message(replyID, in: conversationID) {
                            speaker.speak(finished)
                        }
                        if reply.serverID == settings.activeID {
                            refreshGoalProposalsAfterReply()
                            Task { await refreshCounters() }
                        }
                    case .stopped: finish(replyID, in: conversationID, .stopped)
                    case .error(let message): finish(replyID, in: conversationID, .failed, error: message)
                    }
                }
            } catch is CancellationError {
                break
            } catch let error as URLError where error.code == .cancelled {
                break
            } catch MarcelAPIError.missionNotFound {
                finish(replyID, in: conversationID, .failed, error: MarcelAPIError.missionNotFound.localizedDescription)
                break
            } catch MarcelAPIError.unauthorized {
                serverStatus = .unauthorized
                break
            } catch {
                // Connection lost (app in background, Tailscale down…): the mission goes on, retry.
                if error is URLError { serverStatus = .unreachable }
            }
            guard message(replyID, in: conversationID)?.status == .streaming else { break }
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(15))
        }
        streamTasks[conversationID] = nil
        persist(conversationID)
    }

    private func finish(_ replyID: UUID, in conversationID: UUID, _ status: ChatMessage.Status, error: String? = nil,
                        action: ErrorAction? = nil) {
        updateMessage(replyID, in: conversationID) { $0.status = status }
        let carriedOut = message(replyID, in: conversationID)?.actions.contains { $0.id.hasPrefix("auto-") } ?? false
        if carriedOut || conversations.first(where: { $0.id == conversationID })?.assistantID != nil {
            // Marcel may have changed a setting, made an assistant or a goal: shown at once.
            Task { await refreshAssistants() }
        }
        guard let error, conversationID == currentID else { return }
        if error.hasPrefix("Budget de tokens") {
            report(error, action: .openSettings(.proactive, label: "Voir la consommation"))
            Task { await refreshCounters() }
        } else {
            report(error, action: action)
        }
    }

    // MARK: - The iPhone as the bots' hands

    /// A reply ended with an ```iphone``` block the rules let through: done now. Not twice in a row
    /// though: after an iPhone answer, the next request waits for « Autoriser ».
    private func iPhoneAsked(_ replyID: UUID, in conversationID: UUID) async {
        guard let reply = message(replyID, in: conversationID),
              let action = reply.actions.first(where: { $0.id == "iphone-0" && $0.status == "pending" }),
              let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        let lastUser = conversation.messages.last { $0.role == .user }
        if lastUser?.via == "iPhone" {
            let kind = (action.detail ?? "").hasPrefix("Ajouter") ? "iphone_ecriture" : "iphone"
            updateMessage(replyID, in: conversationID) { message in
                guard let index = message.actions.firstIndex(where: { $0.id == action.id }) else { return }
                message.actions[index].id = "auto-ask-\(kind)-0"
                message.actions[index].status = "cancelled"
                message.actions[index].detail = (action.detail ?? "").replacingOccurrences(of: "…", with: "") + " — attend ton accord"
            }
            persist(conversationID, touch: false)
            return
        }
        await runOnIPhone(action, in: replyID)
    }

    /// Reads or writes on the iPhone, shows it on the card, then sends what it found to the bot as
    /// the next message (marked « via iPhone »), which answers with it.
    func runOnIPhone(_ action: MissionAction, in messageID: UUID) async {
        guard !emergencyActive, let query = action.query,
              let conversation = conversations.first(where: { $0.messages.contains { $0.id == messageID } }) else { return }
        let id = conversation.id
        updateMessage(messageID, in: id) { message in
            guard let index = message.actions.firstIndex(where: { $0.id == action.id }) else { return }
            message.actions[index].status = "running"
        }
        let result = await IPhoneHands.run(query)
        updateMessage(messageID, in: id) { message in
            guard let index = message.actions.firstIndex(where: { $0.id == action.id }) else { return }
            message.actions[index].status = "done"
            message.actions[index].detail = result.summary
        }
        persist(id, touch: false)
        // The reply that asked has finished streaming by now; wait for it if not.
        while isStreaming(id) { try? await Task.sleep(for: .milliseconds(200)) }
        guard let api = settings.api else { return }
        let answer = ChatMessage(role: .user, content: "📱 " + result.text)
        mutate(id) { $0.messages.append(answer) }
        updateMessage(answer.id, in: id) { $0.via = "iPhone" }
        startReply(in: id, after: answer.id, using: api)
    }

    private func api(forServer serverID: UUID?) -> MarcelAPI? {
        guard let serverID else { return settings.api }
        return settings.profiles.first { $0.id == serverID }.flatMap(settings.api(for:))
    }

    // MARK: - Helpers

    private func dropCurrentIfEmpty() {
        if conversation.messages.isEmpty {
            conversations.removeAll { $0.id == currentID }
        }
    }

    private func mutate(_ id: UUID, _ change: (inout Conversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        change(&conversations[index])
    }

    private func message(_ messageID: UUID, in conversationID: UUID) -> ChatMessage? {
        conversations.first { $0.id == conversationID }?.messages.first { $0.id == messageID }
    }

    private func updateMessage(_ messageID: UUID, in conversationID: UUID, _ change: (inout ChatMessage) -> Void) {
        mutate(conversationID) { conversation in
            guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else { return }
            change(&conversation.messages[index])
        }
    }

    private func persist(_ id: UUID, touch: Bool = true) {
        if touch { mutate(id) { $0.updatedAt = .now } }
        guard let conversation = conversations.first(where: { $0.id == id }), !conversation.messages.isEmpty,
              !conversation.isPrivate else { return }
        cache.save(conversation)
    }
}
