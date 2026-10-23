import Foundation

nonisolated struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    enum Role: String, Codable, Sendable {
        case user, assistant
    }

    enum Status: String, Codable, Sendable {
        case complete, streaming, stopped, failed
    }

    let id: UUID
    let role: Role
    var content: String
    var status: Status
    let createdAt: Date
    var attachments: [Attachment]
    /// Server-side mission generating this reply, so it can be followed again after the app was closed.
    var missionID: String?
    /// The saved server the mission runs on.
    var serverID: UUID?
    /// Model that wrote this reply.
    var model: String?
    /// Steps the agent took (commands, reads…) while writing this reply.
    var actions: [MissionAction] = []

    init(id: UUID = UUID(), role: Role, content: String, status: Status = .complete,
         createdAt: Date = .now, attachments: [Attachment] = [], serverID: UUID? = nil, model: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.status = status
        self.createdAt = createdAt
        self.attachments = attachments
        self.serverID = serverID
        self.model = model
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, status, createdAt, attachments, missionID, serverID, model, actions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        status = try container.decode(Status.self, forKey: .status)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        // Messages cached before attachments existed have no such key.
        attachments = try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        missionID = try container.decodeIfPresent(String.self, forKey: .missionID)
        serverID = try container.decodeIfPresent(UUID.self, forKey: .serverID)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        actions = try container.decodeIfPresent([MissionAction].self, forKey: .actions) ?? []
    }
}

nonisolated struct Conversation: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    var updatedAt: Date
    var projectID: UUID?
    /// Illustration chosen by the user; nil means automatic.
    var mood: MarcelMood?

    init(id: UUID = UUID(), title: String = "Nouvelle conversation", messages: [ChatMessage] = [],
         updatedAt: Date = .now, projectID: UUID? = nil, mood: MarcelMood? = nil) {
        self.id = id
        self.title = title
        self.messages = messages
        self.updatedAt = updatedAt
        self.projectID = projectID
        self.mood = mood
    }
}

nonisolated struct Project: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}
