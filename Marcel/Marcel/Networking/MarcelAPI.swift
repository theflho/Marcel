import Foundation

/// Events streamed by `POST /v1/chat/stream`.
/// Each SSE `data:` line carries one JSON object: {"type": "delta"|"done"|"error", ...}.
nonisolated enum StreamEvent: Sendable, Equatable {
    case delta(String)
    case done
    case error(String)
}

nonisolated enum MarcelAPIError: LocalizedError {
    case notConfigured
    case unauthorized
    case http(Int, String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Adresse du serveur non configurée."
        case .unauthorized: "Jeton refusé par le serveur."
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

    /// HTTP status of `GET /health`, or nil when the server can't be reached.
    func health() async -> Int? {
        var request = URLRequest(url: baseURL.appending(path: "health"), timeoutInterval: 5)
        authorize(&request)
        guard let (_, response) = try? await Self.session.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }

    func streamChat(conversationID: UUID, messages: [ChatMessage]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL.appending(path: "v1/chat/stream"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    authorize(&request)
                    request.httpBody = try JSONEncoder().encode(ChatRequest(
                        conversationId: conversationID.uuidString,
                        messages: messages.map { .init(role: $0.role.rawValue, content: $0.content) }
                    ))

                    let (bytes, response) = try await Self.session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        if status == 401 || status == 403 { throw MarcelAPIError.unauthorized }
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 300 { break } }
                        throw MarcelAPIError.http(status, body)
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let event = Self.decode(payload) else { continue }
                        continuation.yield(event)
                        if case .done = event { break }
                        if case .error(let message) = event { throw MarcelAPIError.server(message) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
        case "delta": return .delta(wire.text ?? "")
        case "done": return .done
        case "error": return .error(wire.message ?? "Erreur inconnue du serveur.")
        default: return nil
        }
    }
}

private nonisolated struct ChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let conversationId: String
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case messages
    }
}

private nonisolated struct WireEvent: Decodable {
    let type: String
    let text: String?
    let message: String?
}
