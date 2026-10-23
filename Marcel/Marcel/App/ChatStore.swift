import Foundation
import Observation

enum ServerStatus: Equatable {
    case unknown, checking, reachable, unauthorized, unreachable
}

@Observable
final class ChatStore {
    private static let draftKey = "draft"

    let settings: ServerSettings
    private let cache = ConversationCache()
    /// One stream per conversation, so switching conversations never cuts an answer.
    private var streamTasks: [UUID: Task<Void, Never>] = [:]

    private(set) var conversations: [Conversation]
    private(set) var projects: [Project]
    private(set) var currentID: UUID
    private(set) var serverStatus: ServerStatus = .unknown
    private(set) var lastError: String?

    var draft: String {
        didSet { UserDefaults.standard.set(draft, forKey: Self.draftKey) }
    }

    init(settings: ServerSettings) {
        self.settings = settings
        var loaded = cache.loadAll()
        // A stream interrupted by the app being killed can't resume on-device.
        for c in loaded.indices {
            for m in loaded[c].messages.indices where loaded[c].messages[m].status == .streaming {
                loaded[c].messages[m].status = .stopped
            }
        }
        if loaded.isEmpty { loaded = [Conversation()] }
        conversations = loaded
        projects = cache.loadProjects()
        currentID = loaded[0].id
        draft = UserDefaults.standard.string(forKey: Self.draftKey) ?? ""
    }

    // MARK: - Current conversation

    var conversation: Conversation {
        conversations.first { $0.id == currentID } ?? Conversation()
    }

    var isStreaming: Bool { streamTasks[currentID] != nil }

    func isStreaming(_ id: UUID) -> Bool { streamTasks[id] != nil }

    var canSend: Bool {
        !isStreaming && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    func delete(_ id: UUID) {
        streamTasks[id]?.cancel()
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

    // MARK: - Server

    func checkServer() async {
        guard let api = settings.api else {
            serverStatus = .unreachable
            return
        }
        if serverStatus != .reachable { serverStatus = .checking }
        switch await api.health() {
        case 200: serverStatus = .reachable
        case 401, 403: serverStatus = .unauthorized
        default: serverStatus = .unreachable
        }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        guard let api = settings.api else {
            lastError = MarcelAPIError.notConfigured.localizedDescription
            return
        }

        let id = currentID
        lastError = nil
        draft = ""
        mutate(id) { conversation in
            if conversation.messages.isEmpty {
                conversation.title = String(text.prefix(60))
            }
            conversation.messages.append(ChatMessage(role: .user, content: text))
        }
        let history = conversation.messages.filter { $0.status == .complete }
        let reply = ChatMessage(role: .assistant, content: "", status: .streaming)
        mutate(id) { $0.messages.append(reply) }
        persist(id)

        let stream = api.streamChat(conversationID: id, messages: history)
        streamTasks[id] = Task { [weak self] in
            await self?.consume(stream, conversationID: id, replyID: reply.id)
        }
    }

    func stop() {
        streamTasks[currentID]?.cancel()
    }

    private func consume(_ stream: AsyncThrowingStream<StreamEvent, Error>, conversationID: UUID, replyID: UUID) async {
        do {
            for try await event in stream {
                if case .delta(let text) = event {
                    updateMessage(replyID, in: conversationID) { $0.content += text }
                }
            }
            updateMessage(replyID, in: conversationID) { $0.status = Task.isCancelled ? .stopped : .complete }
            serverStatus = .reachable
        } catch is CancellationError {
            updateMessage(replyID, in: conversationID) { $0.status = .stopped }
        } catch let error as URLError where error.code == .cancelled {
            updateMessage(replyID, in: conversationID) { $0.status = .stopped }
        } catch {
            updateMessage(replyID, in: conversationID) { $0.status = .failed }
            if conversationID == currentID { lastError = error.localizedDescription }
            if error is URLError { serverStatus = .unreachable }
        }
        streamTasks[conversationID] = nil
        persist(conversationID)
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
