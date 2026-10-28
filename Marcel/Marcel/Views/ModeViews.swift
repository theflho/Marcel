import SwiftUI

// Marcel and each assistant are bots, like in Grok Bot: each is one conversation that continues,
// opened from the menu (or "/planning"). « Repartir de zéro » puts it in the bot's history.

extension Assistant {
    /// The examples its welcome gives (« lis le planning à 7 h »…), as suggestions to touch. Only
    /// from its last paragraph ("Demande-moi…"): the ones before name buttons (« Refuser »).
    var suggestions: [String] {
        var found: [String] = []
        var rest = Substring(welcome.components(separatedBy: "\n\n").last ?? welcome)
        while let open = rest.range(of: "«"), let close = rest[open.upperBound...].range(of: "»") {
            let quote = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if quote.count > 2, quote.count <= 60 { found.append(quote.prefix(1).uppercased() + quote.dropFirst()) }
            rest = rest[close.upperBound...]
        }
        return Array(found.prefix(3))
    }
}

extension ChatStore {
    /// The assistant the open conversation talks to; nil for Marcel.
    var mode: Assistant? { assistant(for: conversation) }

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
        if conversation.isPrivate { return ("rien n'est gardé", false) }
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

    private static let marcelSuggestions = ["Organise ma semaine", "Résume mes derniers e-mails",
                                            "Fais-moi un brief chaque matin"]

    private var greeting: String {
        Calendar.current.component(.hour, from: .now) >= 18 ? "Bonsoir !" : "Bonjour !"
    }

    /// How conversations work here, said once where it matters: on the empty conversation.
    private func threadLine(_ mode: Assistant?) -> String {
        if store.conversation.isPrivate {
            return "Rien de ce que tu écris ici n'est gardé, ni dans la liste, ni dans la mémoire de Hermes."
        }
        let name = mode?.name ?? "Hermes"
        return store.history(ofBot: mode?.id).isEmpty
            ? "Ta conversation avec \(name) continue d'un jour à l'autre : pas besoin d'en ouvrir une nouvelle. Touche son nom en haut pour repartir de zéro."
            : "Nouveau départ avec \(name). Les anciennes conversations sont gardées : touche son nom en haut › Anciennes conversations."
    }

    var body: some View {
        let mode = store.mode
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                MarcelAvatar(size: 56, bot: mode?.id)
                Text(store.conversation.isPrivate ? "Conversation privée" : "\(greeting) Ici Hermes.")
                    .font(.title3.weight(.semibold))
                Text(mode.map { "\($0.name) : \($0.summary)" } ?? "Qu'est-ce que je fais pour toi ?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(threadLine(mode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.surface, in: .rect(cornerRadius: 14))
                    .padding(.top, 4)
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

            if let mode {
                BotPageWelcome(assistantID: mode.id)
            }

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
