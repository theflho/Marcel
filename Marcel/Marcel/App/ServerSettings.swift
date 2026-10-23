import Foundation
import Observation

/// One backend Marcel can talk to (the VPS, the Mac for development…).
nonisolated struct ServerProfile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var url: String

    init(id: UUID = UUID(), name: String, url: String) {
        self.id = id
        self.name = name
        self.url = url
    }

    var baseURL: URL? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https" || url.scheme == "http", url.host() != nil else {
            return nil
        }
        return url
    }

    fileprivate var tokenAccount: String { "backendToken-\(id.uuidString)" }
}

/// Saved servers and the active one (UserDefaults); each server's token lives in the Keychain.
@Observable
final class ServerSettings {
    private static let profilesKey = "serverProfiles"
    private static let activeKey = "activeServerID"
    // Single-server settings from earlier versions, migrated on first launch.
    private static let legacyURLKey = "serverURL"
    private static let legacyTokenAccount = "backendToken"

    static let vpsURL = "https://vps-ecc4ab15.tail9a9dd4.ts.net"
    static let localURL = "http://localhost:8000"

    private(set) var profiles: [ServerProfile] {
        didSet { save() }
    }

    var activeID: UUID {
        didSet { UserDefaults.standard.set(activeID.uuidString, forKey: Self.activeKey) }
    }

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.profilesKey),
           let saved = try? JSONDecoder().decode([ServerProfile].self, from: data), !saved.isEmpty {
            profiles = saved
            let active = defaults.string(forKey: Self.activeKey).flatMap(UUID.init(uuidString:))
            activeID = saved.contains { $0.id == active } ? active! : saved[0].id
            return
        }

        var initial = [ServerProfile(name: "VPS", url: Self.vpsURL)]
        #if targetEnvironment(simulator)
        initial.append(ServerProfile(name: "Mac (développement)", url: Self.localURL))
        #endif
        #if targetEnvironment(simulator)
        var index = 1
        #else
        var index = 0
        #endif
        if let legacyURL = defaults.string(forKey: Self.legacyURLKey) {
            if let existing = initial.firstIndex(where: { $0.url == legacyURL }) {
                index = existing
            } else {
                initial.insert(ServerProfile(name: "Mon serveur", url: legacyURL), at: 0)
                index = 0
            }
            defaults.removeObject(forKey: Self.legacyURLKey)
        }
        if let token = Keychain.string(for: Self.legacyTokenAccount) {
            Keychain.set(token, for: initial[index].tokenAccount)
            Keychain.set(nil, for: Self.legacyTokenAccount)
        }
        activeID = initial[index].id
        profiles = initial
        save()
        defaults.set(activeID.uuidString, forKey: Self.activeKey)
    }

    var active: ServerProfile {
        profiles.first { $0.id == activeID } ?? profiles[0]
    }

    var api: MarcelAPI? { api(for: active) }

    func api(for profile: ServerProfile) -> MarcelAPI? {
        profile.baseURL.map { MarcelAPI(baseURL: $0, token: token(for: profile)) }
    }

    // MARK: Editing

    func token(for profile: ServerProfile) -> String {
        Keychain.string(for: profile.tokenAccount) ?? ""
    }

    func setToken(_ token: String, for profile: ServerProfile) {
        Keychain.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: profile.tokenAccount)
    }

    func update(_ profile: ServerProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
    }

    @discardableResult
    func add(name: String, url: String) -> ServerProfile {
        let profile = ServerProfile(name: name, url: url)
        profiles.append(profile)
        return profile
    }

    /// The last server cannot be removed, so the app always has somewhere to send messages.
    func remove(_ profile: ServerProfile) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == profile.id }
        Keychain.set(nil, for: profile.tokenAccount)
        if activeID == profile.id { activeID = profiles[0].id }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Self.profilesKey)
        }
    }
}
