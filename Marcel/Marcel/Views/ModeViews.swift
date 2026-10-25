import SwiftUI

// Marcel and each assistant are bots, like in Grok Bot: each has its own conversations, opened from
// the menu (or "/planning"). A conversation stays with the bot it was started with.

extension Assistant {
    /// The examples its welcome gives (« lis le planning à 7 h »…), as suggestions to touch.
    var suggestions: [String] {
        var found: [String] = []
        var rest = Substring(welcome)
        while let open = rest.range(of: "«"), let close = rest[open.upperBound...].range(of: "»") {
            let quote = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if quote.count > 2, quote.count <= 60 { found.append(quote.prefix(1).uppercased() + quote.dropFirst()) }
            rest = rest[close.upperBound...]
        }
        return Array(found.prefix(3))
    }

    /// "au Planning", "aux Mails", "à Veille"…
    var withArticle: String {
        switch id {
        case "planning", "pointage": "au \(name)"
        case "recrutements", "mails": "aux \(name)"
        default: "à \(name)"
        }
    }
}

extension ChatStore {
    /// The assistant the open conversation talks to; nil for Marcel.
    var mode: Assistant? { assistant(for: conversation) }

    var modeMood: MarcelMood {
        mode.map { mood(for: $0) } ?? conversation.displayMood
    }

    /// Under the name in the header, like a messaging app: what the reply is doing, else whether
    /// the server answers.
    /// What the reply is doing while a step runs ("lit tes e-mails…"), nil otherwise.
    var runningActivity: String? {
        guard isStreaming, let last = conversation.messages.last, last.role == .assistant,
              last.actions.contains(where: { $0.status == "running" }) else { return nil }
        let phrase = StepsLine.activity(of: last.actions)
        return phrase.prefix(1).lowercased() + phrase.dropFirst()
    }

    var headerStatus: (text: String, active: Bool)? {
        if isStreaming {
            if let activity = runningActivity { return (activity, true) }
            guard let last = conversation.messages.last, last.role == .assistant else { return ("réfléchit…", true) }
            return (last.content.isEmpty ? "réfléchit…" : "écrit…", true)
        }
        if conversation.isPrivate { return ("privée · rien n'est gardé", false) }
        switch serverStatus {
        case .reachable: return ("en ligne", false)
        case .unreachable, .unauthorized: return ("hors ligne", false)
        default: return nil
        }
    }
}

/// A new conversation: the bot, small, a short greeting and what to ask (like Meta AI).
struct WelcomeView: View {
    @Environment(ChatStore.self) private var store

    private static let marcelSuggestions = ["Mes missions de la semaine", "Résume mes derniers e-mails",
                                            "Fais-moi un brief chaque matin"]

    private var greeting: String {
        Calendar.current.component(.hour, from: .now) >= 18 ? "Bonsoir !" : "Bonjour !"
    }

    var body: some View {
        let mode = store.mode
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                MarcelAvatar(size: 56, mood: store.modeMood, cutout: true)
                Text(mode.map { "\(greeting) Ici \($0.name)." } ?? greeting)
                    .font(.title3.weight(.semibold))
                Text(mode?.summary ?? "Qu'est-ce que je fais pour toi ?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let mode, !mode.status.isEmpty {
                    Text(mode.status)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 8) {
                let suggestions = mode.map { $0.suggestions.isEmpty ? ["Qu'est-ce que tu sais faire ?"] : $0.suggestions }
                    ?? Self.marcelSuggestions
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        store.sendSuggestion(suggestion)
                    } label: {
                        Label(suggestion, systemImage: "arrow.up.right")
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.surface, in: .rect(cornerRadius: 16))
                    }
                    .tint(.primary)
                    .disabled(store.emergencyActive)
                }
            }
            .padding(.horizontal)

            if mode?.id == "recrutements" {
                OffersList(offers: store.offers)
                    .padding(12)
                    .background(Theme.assistantBubble, in: .rect(cornerRadius: 20))
                    .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.bottom, 8)
    }
}

/// What Marcel suggests to ask next, under his last reply.
struct FollowupsView: View {
    @Environment(ChatStore.self) private var store
    let questions: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(questions, id: \.self) { question in
                Button {
                    store.sendSuggestion(question)
                } label: {
                    Label(question, systemImage: "arrow.turn.down.right")
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .glass(in: .capsule)
                }
                .tint(.primary)
                .disabled(store.emergencyActive)
            }
        }
        .padding(.horizontal)
        .transition(.opacity)
    }
}
