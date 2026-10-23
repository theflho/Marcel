import Foundation
import Observation

/// Backend address (UserDefaults) and access token (Keychain).
@Observable
final class ServerSettings {
    private static let urlKey = "serverURL"
    private static let tokenAccount = "backendToken"

    #if targetEnvironment(simulator)
    static let defaultURL = "http://localhost:8000"
    #else
    static let defaultURL = "https://vps-ecc4ab15.tail9a9dd4.ts.net"
    #endif

    var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Self.urlKey) }
    }

    var token: String {
        didSet { Keychain.set(token, for: Self.tokenAccount) }
    }

    init() {
        serverURL = UserDefaults.standard.string(forKey: Self.urlKey) ?? Self.defaultURL
        token = Keychain.string(for: Self.tokenAccount) ?? ""
    }

    var api: MarcelAPI? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https" || url.scheme == "http", url.host() != nil else {
            return nil
        }
        return MarcelAPI(baseURL: url, token: token)
    }
}
