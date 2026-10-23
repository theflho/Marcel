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

    init(id: UUID = UUID(), role: Role, content: String, status: Status = .complete, createdAt: Date = .now) {
        self.id = id
        self.role = role
        self.content = content
        self.status = status
        self.createdAt = createdAt
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
