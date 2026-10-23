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

    private(set) var conversations: [Conversation]
    private(set) var projects: [Project]
    private(set) var currentID: UUID
    private(set) var serverStatus: ServerStatus = .unknown
    private(set) var lastError: String? {
        didSet { lastErrorAction = nil }
    }
    private(set) var lastErrorAction: ErrorAction?
    /// Today's token usage on the active server, refreshed with each health check and after replies.
    private(set) var tokenUsage: TokenUsage?
    /// Set to open Settings at a given place; SettingsView takes it when it appears.
    var settingsRequest: SettingsRoute?

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

    /// Conversations worth listing: the open one plus any that have messages.
    var listedConversations: [Conversation] {
        conversations
            .filter { !$0.messages.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func select(_ id: UUID) {
        guard id != currentID else { return }
        dropCurrentIfEmpty()
        currentID = id
        lastError = nil
        goalProposals = []
        Task { await refreshGoalProposals() }
    }

    func newConversation(in projectID: UUID? = nil) {
        if conversation.messages.isEmpty {
            // Reuse the blank conversation instead of stacking empty ones.
            mutate(currentID) { $0.projectID = projectID }
            return
        }
        let fresh = Conversation(projectID: projectID)
        conversations.append(fresh)
        currentID = fresh.id
        lastError = nil
        goalProposals = []
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
            if health?.emergency == true {
                // Stopped from elsewhere (another device, curl): honour it here too.
                applyEmergencyLocally()
                return
            }
            if models.isEmpty, let loaded = try? await api.models() { models = loaded }
            resumeMissions()
            await refreshGoalProposals()
        case 401, 403: serverStatus = .unauthorized
        default: serverStatus = .unreachable
        }
    }

    func useServer(_ profile: ServerProfile) {
        guard profile.id != settings.activeID else { return }
        settings.activeID = profile.id
        models = []
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

        streamTasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.uploadAttachments(of: userMessageID, in: id, using: api)
                let history = self.conversations.first { $0.id == id }?.messages.filter { $0.status == .complete } ?? []
                let mission = try await api.startMission(conversationID: id, messages: history, model: model,
                                                         deviceContext: Agenda.upcoming())
                self.updateMessage(reply.id, in: id) { $0.missionID = mission.id }
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
        guard let error, conversationID == currentID else { return }
        if error.hasPrefix("Budget de tokens") {
            report(error, action: .openSettings(.proactive, label: "Voir la consommation"))
            Task { await refreshCounters() }
        } else {
            report(error, action: action)
        }
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
        guard let conversation = conversations.first(where: { $0.id == id }), !conversation.messages.isEmpty else { return }
        cache.save(conversation)
    }
}
