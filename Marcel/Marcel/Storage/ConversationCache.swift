import Foundation

/// Local JSON cache so recent conversations stay readable offline.
/// The server stays the source of truth once conversations are synced.
nonisolated struct ConversationCache: Sendable {
    private let directory: URL
    private let projectsFile: URL

    init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appending(path: "Conversations", directoryHint: .isDirectory)
        projectsFile = base.appending(path: "projects.json")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func save(_ conversation: Conversation) {
        let url = directory.appending(path: "\(conversation.id.uuidString).json")
        do {
            let data = try JSONEncoder.marcel.encode(conversation)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            print("Cache write failed: \(error)")
        }
    }

    func loadAll() -> [Conversation] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder.marcel.decode(Conversation.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory.appending(path: "\(id.uuidString).json"))
    }

    func clear() throws {
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: file)
        }
        if FileManager.default.fileExists(atPath: projectsFile.path) {
            try FileManager.default.removeItem(at: projectsFile)
        }
    }

    func saveProjects(_ projects: [Project]) {
        guard let data = try? JSONEncoder.marcel.encode(projects) else { return }
        try? data.write(to: projectsFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func loadProjects() -> [Project] {
        guard let data = try? Data(contentsOf: projectsFile) else { return [] }
        return (try? JSONDecoder.marcel.decode([Project].self, from: data)) ?? []
    }
}

nonisolated extension JSONEncoder {
    static var marcel: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

nonisolated extension JSONDecoder {
    static var marcel: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
