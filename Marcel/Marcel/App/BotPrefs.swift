import Foundation

/// How the user arranges the bots on this iPhone, like Grok Bot's sidebar (Pin, Hide from sidebar)
/// and each bot's Notifications switch. Marcel (nil) is a bot too, under the id "marcel".
nonisolated enum BotPrefs {
    static let pinnedKey = "pinnedBots"
    static let hiddenKey = "hiddenBots"
    static let mutedKey = "mutedBots"

    static func key(_ assistantID: String?) -> String { assistantID ?? "marcel" }

    static func list(_ name: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: name) ?? []
    }

    static func contains(_ name: String, _ assistantID: String?) -> Bool {
        list(name).contains(key(assistantID))
    }

    static func set(_ name: String, _ assistantID: String?, _ on: Bool) {
        var ids = list(name).filter { $0 != key(assistantID) }
        if on { ids.append(key(assistantID)) }
        UserDefaults.standard.set(ids, forKey: name)
    }

    /// Whether this bot may notify: on unless the user switched it off in its card.
    static func notifies(_ assistantID: String?) -> Bool {
        !contains(mutedKey, assistantID)
    }
}
