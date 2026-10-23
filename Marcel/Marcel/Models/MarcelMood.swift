import Foundation

/// Which illustration of Marcel goes with a conversation.
/// Picked automatically from the topic unless the user chose one.
nonisolated enum MarcelMood: String, Codable, CaseIterable, Identifiable, Sendable {
    case tree, sleep, laptop, coffee, reading, music, roadtrip, dog, pool, sport, cooking, hammock

    var id: String { rawValue }

    var imageName: String {
        self == .tree ? "MarcelAvatar" : "Marcel-\(rawValue)"
    }

    var label: String {
        switch self {
        case .tree: "Dans l'arbre"
        case .sleep: "Sieste"
        case .laptop: "Au travail"
        case .coffee: "Café"
        case .reading: "Lecture"
        case .music: "Musique"
        case .roadtrip: "En voiture"
        case .dog: "Avec le chien"
        case .pool: "Piscine"
        case .sport: "Sport"
        case .cooking: "Cuisine"
        case .hammock: "Hamac"
        }
    }

    /// Word prefixes (lowercase, no accents) that point to this mood.
    private var keywords: [String] {
        switch self {
        case .tree: []
        case .sleep: ["dormir", "sommeil", "fatigu", "nuit", "sieste", "insomni"]
        case .laptop: ["code", "coder", "bug", "swift", "python", "api", "serveur", "deploi", "script",
                       "ordi", "programm", "develop", "backend", "git", "docker", "excel", "mail"]
        case .coffee: ["cafe", "matin", "routine", "planning", "agenda", "reunion", "organis", "journee"]
        case .reading: ["livre", "lire", "lecture", "resum", "article", "pdf", "document", "etudi",
                        "apprendre", "explique", "histoire"]
        case .music: ["musique", "chanson", "playlist", "podcast", "concert", "album", "spotify"]
        case .roadtrip: ["voyage", "trajet", "route", "voiture", "itineraire", "train", "avion", "billet"]
        case .dog: ["chien", "chat", "animal", "animaux", "veterinaire", "chiot"]
        case .pool: ["plage", "piscine", "vacances", "mer", "nager", "soleil"]
        case .sport: ["sport", "muscu", "entrainement", "courir", "running", "gym", "fitness", "velo", "marathon"]
        case .cooking: ["recette", "cuisin", "repas", "diner", "dejeuner", "manger", "plat", "gateau"]
        case .hammock: ["detente", "repos", "weekend", "stress", "meditation", "relax"]
        }
    }

    /// Best match for a piece of text, or nil when nothing stands out.
    static func guess(from text: String) -> MarcelMood? {
        let words = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split { !$0.isLetter }
        guard !words.isEmpty else { return nil }
        let scores = allCases.map { mood in
            (mood, words.filter { word in mood.keywords.contains { word.hasPrefix($0) } }.count)
        }
        guard let best = scores.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }
}

extension Conversation {
    /// The user's choice, else a guess from the topic, else a stable pick so conversations still differ.
    var displayMood: MarcelMood {
        if let mood { return mood }
        guard let first = messages.first(where: { $0.role == .user }) else { return .tree }
        if let guessed = MarcelMood.guess(from: title + " " + first.content) { return guessed }
        let seed = withUnsafeBytes(of: id.uuid) { $0.reduce(0) { $0 &+ Int($1) } }
        return MarcelMood.allCases[seed % MarcelMood.allCases.count]
    }
}
