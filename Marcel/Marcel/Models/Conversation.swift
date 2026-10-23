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

    init(id: UUID = UUID(), role: Role, content: String, status: Status = .complete,
         createdAt: Date = .now, attachments: [Attachment] = []) {
        self.id = id
        self.role = role
        self.content = content
        self.status = status
        self.createdAt = createdAt
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, status, createdAt, attachments
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
    }
}

nonisolated struct Conversation: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    var updatedAt: Date
    var projectID: UUID?

    init(id: UUID = UUID(), title: String = "Nouvelle conversation", messages: [ChatMessage] = [],
         updatedAt: Date = .now, projectID: UUID? = nil) {
        self.id = id
        self.title = title
        self.messages = messages
        self.updatedAt = updatedAt
        self.projectID = projectID
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
