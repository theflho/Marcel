import SwiftUI

/// A bot's page: a table the server works out each time it opens (missions of the week, offers
/// waiting…), without any model, so it is always the latest. The user chooses whether it shows when
/// the bot opens; Marcel never pins it himself.
struct BotPageView: View {
    @Environment(ChatStore.self) private var store
    let assistantID: String
    @State private var page: BotPage?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let page, !page.markdown.isEmpty {
                HStack {
                    Text(page.title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(page.at, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                MarkdownView(text: page.markdown)
                    .font(.footnote)
            } else if failed {
                Text("Page indisponible pour l'instant.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if page == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: assistantID) { await load() }
    }

    private func load() async {
        guard !store.emergencyActive, let api = store.settings.api else { failed = true; return }
        do {
            page = try await api.botPage(id: assistantID)
            failed = false
        } catch {
            failed = true
        }
    }
}

/// The page in a bot's card, with the user's choice to show it when the bot opens.
struct BotPageSection: View {
    let assistantID: String
    @AppStorage private var shown: Bool

    init(assistantID: String) {
        self.assistantID = assistantID
        _shown = AppStorage(wrappedValue: false, Self.key(assistantID))
    }

    static func key(_ id: String) -> String { "botPage.\(id)" }
    /// The bots the server has a page for.
    static let withPage: Set<String> = ["planning", "pointage", "recrutements", "veille"]

    var body: some View {
        if Self.withPage.contains(assistantID) {
            Section {
                BotPageView(assistantID: assistantID)
                Toggle("Afficher à l'ouverture du bot", isOn: $shown)
            } header: {
                Text("Page")
            } footer: {
                Text("Recalculée par le serveur à chaque ouverture, sans modèle : toujours à jour, rien ne s'invente.")
            }
        }
    }
}

/// The page at the top of a new conversation with the bot, when the user chose so in its card.
struct BotPageWelcome: View {
    let assistantID: String
    @AppStorage private var shown: Bool

    init(assistantID: String) {
        self.assistantID = assistantID
        _shown = AppStorage(wrappedValue: false, BotPageSection.key(assistantID))
    }

    var body: some View {
        if shown {
            BotPageView(assistantID: assistantID)
                .padding(12)
                .background(Theme.assistantBubble, in: .rect(cornerRadius: 20))
                .padding(.horizontal)
        }
    }
}
