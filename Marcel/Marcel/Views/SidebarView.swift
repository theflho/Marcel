import SwiftUI

/// Side drawer, like Grok Bot's: one row per bot, and each bot is one conversation that continues.
/// Earlier conversations (put aside by « Repartir de zéro ») live in the bot's history and the search.
struct SidebarView: View {
    @Environment(ChatStore.self) private var store
    var onClose: () -> Void
    var onOpenSettings: () -> Void
    var onOpenAssistants: () -> Void
    @State private var query = ""
    @State private var renaming: UUID?
    /// Bumped when a bot is pinned or hidden, so the list reads BotPrefs again.
    @State private var botPrefsVersion = 0
    @State private var hiddenExpanded = false
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            List {
                if query.isEmpty {
                    botsSection
                    privateSection
                } else {
                    searchResults
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            footer
        }
        .alert("Renommer", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nom", text: $renameText)
            Button("Annuler", role: .cancel) {}
            Button("OK") {
                if let renaming { store.rename(renaming, to: renameText) }
                renaming = nil
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: 10) {
            Text("Marcel")
                .font(.title2.weight(.bold))
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Rechercher dans les conversations", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button("Effacer", systemImage: "xmark.circle.fill") { query = "" }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.surface, in: .rect(cornerRadius: 12))
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// One bot of the menu: Marcel (nil id) or an assistant.
    private struct BotItem: Identifiable {
        let id: String?
        let name: String
        var key: String { BotPrefs.key(id) }
    }

    /// Marcel then the assistants, pinned ones first (like Grok Bot's Pin), hidden ones apart.
    private var bots: (shown: [BotItem], hidden: [BotItem]) {
        _ = botPrefsVersion
        let every = [BotItem(id: nil, name: "Marcel")]
            + store.assistants.map { BotItem(id: $0.id, name: $0.name) }
        let pinned = BotPrefs.list(BotPrefs.pinnedKey), hidden = Set(BotPrefs.list(BotPrefs.hiddenKey))
        let shown = every.filter { !hidden.contains($0.key) }
        let first = pinned.compactMap { key in shown.first { $0.key == key } }
        return (first + shown.filter { !pinned.contains($0.key) }, every.filter { hidden.contains($0.key) })
    }

    /// Marcel and the assistants, like Grok Bot's list of bots: touch one to talk to it.
    private var botsSection: some View {
        Section {
            let list = bots
            ForEach(list.shown) { bot in
                botRow(id: bot.id, name: bot.name)
                    .contextMenu { botMenu(bot) }
            }
            if !list.hidden.isEmpty {
                DisclosureGroup("Bots masqués (\(list.hidden.count))", isExpanded: $hiddenExpanded) {
                    ForEach(list.hidden) { bot in
                        botRow(id: bot.id, name: bot.name)
                            .contextMenu { botMenu(bot) }
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            Button {
                onOpenAssistants()
            } label: {
                Label("Nouveau bot", systemImage: "plus")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } header: {
            Text("Tes bots")
        } footer: {
            Text("Un bot = une conversation qui continue d'un jour à l'autre. Pour tout reprendre à zéro, touche son nom en haut du chat : l'ancienne conversation va dans son historique.")
                .font(.caption)
        }
    }

    /// A conversation with Marcel that keeps nothing: no memory, not in the list.
    private var privateSection: some View {
        Section {
            Button {
                store.newPrivateConversation()
                onClose()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "eye.slash")
                        .frame(width: 36, height: 36)
                        .background(Theme.surface, in: .rect(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Conversation privée")
                            .font(.body.weight(store.conversation.isPrivate ? .semibold : .regular))
                        Text("Avec Marcel, rien n'est gardé")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .tint(.primary)
            .listRowBackground(store.conversation.isPrivate ? Theme.surface.opacity(0.6) : Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private func botMenu(_ bot: BotItem) -> some View {
        let pinned = BotPrefs.contains(BotPrefs.pinnedKey, bot.id)
        let hidden = BotPrefs.contains(BotPrefs.hiddenKey, bot.id)
        if !hidden {
            Button(pinned ? "Désépingler" : "Épingler", systemImage: pinned ? "pin.slash" : "pin") {
                BotPrefs.set(BotPrefs.pinnedKey, bot.id, !pinned)
                botPrefsVersion += 1
            }
        }
        Button(hidden ? "Afficher dans le menu" : "Masquer du menu", systemImage: hidden ? "eye" : "eye.slash") {
            BotPrefs.set(BotPrefs.hiddenKey, bot.id, !hidden)
            if !hidden { BotPrefs.set(BotPrefs.pinnedKey, bot.id, false) }
            botPrefsVersion += 1
        }
    }

    private func botRow(id: String?, name: String) -> some View {
        let current = store.conversation.assistantID == id && !store.conversation.isPrivate
        return Button {
            store.openBot(id)
            onClose()
        } label: {
            HStack(spacing: 10) {
                MarcelAvatar(size: 36, bot: id, state: store.face(ofBot: id))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(name)
                            .font(.body.weight(current ? .semibold : .regular))
                        if BotPrefs.contains(BotPrefs.pinnedKey, id) {
                            Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                                .accessibilityLabel("épinglé")
                        }
                    }
                    Text(store.lastLine(ofBot: id) ?? "Pas encore de conversation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .tint(.primary)
        .listRowBackground(current ? Theme.surface.opacity(0.6) : Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var searchResults: some View {
        let needle = query.lowercased()
        let results = store.listedConversations.filter { conversation in
            conversation.title.lowercased().contains(needle)
                || conversation.messages.contains { $0.content.lowercased().contains(needle) }
        }
        Section(results.isEmpty ? "Aucun résultat" : "Conversations, actuelles et passées") {
            ForEach(results) { row(for: $0) }
        }
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Button {
                onOpenAssistants()
            } label: {
                Label("Assistants", systemImage: "person.2")
                    .padding(.vertical)
                    .padding(.leading)
            }
            .tint(.primary)
            Button {
                onOpenSettings()
            } label: {
                Label("Réglages", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .tint(.primary)
            if let usage = store.tokenUsage {
                Button {
                    store.openSettings(.proactive)
                } label: {
                    TokenGauge(usage: usage)
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                }
                .tint(.primary)
                .accessibilityLabel("Tokens du jour : \(usage.today) sur \(usage.budget)")
            }
        }
        .background(.bar)
    }

    // MARK: Rows

    private func row(for conversation: Conversation) -> some View {
        Button {
            store.select(conversation.id)
            onClose()
        } label: {
            let assistant = store.assistant(for: conversation)
            HStack(spacing: 10) {
                // The face of the bot this conversation talks to, and what it is doing there.
                MarcelAvatar(size: 36, bot: assistant?.id, state: store.face(of: conversation))
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .font(.body.weight(conversation.id == store.currentID ? .semibold : .regular))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        let name = assistant?.name ?? "Marcel"
                        let current = store.thread(ofBot: conversation.assistantID)?.id == conversation.id
                        Text(current ? name : "\(name) · ancienne")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Theme.assistantBubble, in: .capsule)
                        if let last = conversation.messages.last(where: { !$0.content.isEmpty }) {
                            Text(Self.preview(AutoBlocks.strip(last.content)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
                if store.isStreaming(conversation.id) {
                    ProgressView().controlSize(.small)
                }
            }
            .contentShape(.rect)
        }
        .tint(.primary)
        .listRowBackground(conversation.id == store.currentID ? Theme.assistantBubble : Color.clear)
        .swipeActions {
            Button("Supprimer", systemImage: "trash", role: .destructive) { store.delete(conversation.id) }
        }
        .contextMenu {
            Button("Renommer", systemImage: "pencil") {
                renameText = conversation.title
                renaming = conversation.id
            }
            ShareLink(item: transcript(of: conversation))
            Button("Supprimer", systemImage: "trash", role: .destructive) { store.delete(conversation.id) }
        }
    }

    /// One-line preview without Markdown markers.
    private static func preview(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .filter { !"#*`>_|".contains($0) }
            .trimmingCharacters(in: .whitespaces)
    }

    private func transcript(of conversation: Conversation) -> String {
        let name = store.assistant(for: conversation)?.name ?? "Marcel"
        return conversation.messages
            .map { "\($0.role == .user ? "Moi" : name) : \(AutoBlocks.strip($0.content))" }
            .joined(separator: "\n\n")
    }
}

/// Today's tokens against the daily budget, always in sight.
private struct TokenGauge: View {
    let usage: TokenUsage

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(usage.summary)
                .font(.caption.weight(.medium))
                .monospacedDigit()
            ProgressView(value: usage.fraction)
                .tint(usage.fraction >= 1 ? .red : usage.fraction >= 0.8 ? .orange : .accentColor)
                .frame(width: 72)
        }
        .foregroundStyle(.secondary)
    }
}
