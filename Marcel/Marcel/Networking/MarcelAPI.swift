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
    let id: String
    var name: String?
    var detail: String?
    /// "running", "done" or "cancelled".
    var status: String?
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

    var isCore: Bool { tier == "core" }

    enum CodingKeys: String, CodingKey {
        case id, text, tier, importance, pinned, source, uses
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

/// Fields of a fact to change; nil ones are left as they are.
nonisolated struct MemoryChange: Encodable, Sendable {
    var text: String?
    var tier: String?
    var importance: Int?
    var pinned: Bool?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(tier, forKey: .tier)
        try container.encodeIfPresent(importance, forKey: .importance)
        try container.encodeIfPresent(pinned, forKey: .pinned)
    }

    enum CodingKeys: String, CodingKey { case text, tier, importance, pinned }
}

nonisolated struct ServerHealth: Sendable {
    let status: Int
    /// The server-side emergency stop is on: it refuses every mission.
    let emergency: Bool
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
        case .http(let code, let body): "Erreur HTTP \(code)\(body.isEmpty ? "" : " : \(body)")"
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
        return ServerHealth(status: (response as? HTTPURLResponse)?.statusCode ?? 0, emergency: body?.emergency ?? false)
    }

    func models() async throws -> [ModelOption] {
        var request = URLRequest(url: baseURL.appending(path: "v1/models"), timeoutInterval: 10)
        authorize(&request)
        let (data, response) = try await Self.session.data(for: request)
        try Self.check(response, body: data)
        return try JSONDecoder().decode(ModelList.self, from: data).models
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
    func startMission(conversationID: UUID, messages: [ChatMessage], model: String?) async throws -> MissionInfo {
        var request = URLRequest(url: baseURL.appending(path: "v1/missions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            conversationId: conversationID.uuidString,
            messages: messages.map {
                .init(role: $0.role.rawValue, content: $0.content,
                      attachments: $0.attachments.compactMap(\.remoteID))
            },
            model: model
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

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case messages, model
    }
}

private nonisolated struct UndoResult: Decodable {
    let undone: Int
}

private nonisolated struct HealthBody: Decodable {
    let emergency: Bool?
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
