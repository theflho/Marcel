import SwiftUI

/// Side drawer, like Grok Bot's: search, the bots (Marcel and each assistant, each with its own
/// conversations), then every conversation by date (a badge names the bot), the projects folded
/// underneath, Assistants and Réglages.
struct SidebarView: View {
    @Environment(ChatStore.self) private var store
    var onClose: () -> Void
    var onOpenSettings: () -> Void
    var onOpenAssistants: () -> Void
    @AppStorage("projectsExpanded") private var projectsExpanded = false

    @State private var query = ""
    @State private var expandedProjects: Set<UUID> = []
    @State private var renaming: RenameTarget?
    @State private var renameText = ""
    @State private var creatingProject = false
    @State private var newProjectName = ""

    private enum RenameTarget: Identifiable {
        case conversation(UUID), project(UUID)
        var id: UUID {
            switch self {
            case .conversation(let id), .project(let id): id
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            List {
                if query.isEmpty {
                    botsSection
                    ForEach(DateBucket.group(store.listedConversations.filter { $0.projectID == nil }), id: \.bucket) { group in
                        Section(group.bucket.title) {
                            ForEach(group.conversations) { row(for: $0) }
                        }
                    }
                    projectsSection
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
            Button("OK") { applyRename() }
        }
        .alert("Nouveau projet", isPresented: $creatingProject) {
            TextField("Nom du projet", text: $newProjectName)
            Button("Annuler", role: .cancel) {}
            Button("Créer") {
                if let project = store.createProject(named: newProjectName) {
                    withAnimation(.snappy) { _ = expandedProjects.insert(project.id) }
                }
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
                TextField("Rechercher", text: $query)
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
            Button {
                store.newConversation()
                onClose()
            } label: {
                Label("Nouvelle conversation", systemImage: "square.and.pencil")
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .tint(.primary)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// Marcel and the assistants, like Grok Bot's list of bots: touch one to talk to it.
    private var botsSection: some View {
        Section("Bots") {
            botRow(id: nil, name: "Marcel", mood: .tree)
            ForEach(store.assistants) { assistant in
                botRow(id: assistant.id, name: assistant.name, mood: store.mood(for: assistant))
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
        }
    }

    private func botRow(id: String?, name: String, mood: MarcelMood) -> some View {
        let current = store.conversation.assistantID == id && !store.conversation.isPrivate
        return Button {
            store.openBot(id)
            onClose()
        } label: {
            HStack(spacing: 10) {
                MarcelAvatar(size: 36, mood: mood, cutout: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body.weight(current ? .semibold : .regular))
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

    private var projectsSection: some View {
        Section(isExpanded: $projectsExpanded) {
            ForEach(store.projects) { project in
                let items = store.listedConversations.filter { $0.projectID == project.id }
                let isExpanded = expandedProjects.contains(project.id)
                Button {
                    withAnimation(.snappy) {
                        if isExpanded { expandedProjects.remove(project.id) } else { expandedProjects.insert(project.id) }
                    }
                } label: {
                    ProjectRow(project: project, count: items.filter { !$0.messages.isEmpty }.count, isExpanded: isExpanded)
                }
                .tint(.primary)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .contextMenu { projectMenu(project) }
                if isExpanded {
                    Button {
                        store.newConversation(in: project.id)
                        onClose()
                    } label: {
                        Label("Nouvelle conversation ici", systemImage: "square.and.pencil")
                            .font(.subheadline)
                            .padding(.leading, 28)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    ForEach(items) { row(for: $0).padding(.leading, 28) }
                }
            }
            Button {
                newProjectName = ""
                creatingProject = true
            } label: {
                Label("Nouveau projet", systemImage: "plus")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } header: {
            Text(store.projects.isEmpty ? "Projets" : "Projets (\(store.projects.count))")
        }
    }

    @ViewBuilder
    private func projectMenu(_ project: Project) -> some View {
        Button("Nouvelle conversation ici", systemImage: "square.and.pencil") {
            store.newConversation(in: project.id)
            onClose()
        }
        Button("Renommer", systemImage: "pencil") {
            renameText = project.name
            renaming = .project(project.id)
        }
        Button("Supprimer le projet", systemImage: "trash", role: .destructive) {
            expandedProjects.remove(project.id)
            store.deleteProject(project.id)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let needle = query.lowercased()
        let results = store.listedConversations.filter { conversation in
            conversation.title.lowercased().contains(needle)
                || conversation.messages.contains { $0.content.lowercased().contains(needle) }
        }
        Section(results.isEmpty ? "Aucun résultat" : "Résultats") {
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
                MarcelAvatar(size: 36, mood: conversation.displayMood)
                    .overlay(alignment: .bottomTrailing) {
                        // The assistant this conversation talks to, in a corner of Marcel.
                        if let assistant {
                            MarcelAvatar(size: 18, mood: store.mood(for: assistant))
                                .offset(x: 4, y: 4)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .font(.body.weight(conversation.id == store.currentID ? .semibold : .regular))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let assistant {
                            Text(assistant.name)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Theme.assistantBubble, in: .capsule)
                        }
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
                renaming = .conversation(conversation.id)
            }
            Menu("Déplacer vers", systemImage: "folder") {
                Button("Aucun projet") { store.move(conversation.id, to: nil) }
                ForEach(store.projects) { project in
                    Button(project.name) { store.move(conversation.id, to: project.id) }
                }
            }
            Menu("Illustration", systemImage: "photo") {
                MoodPicker(conversation: conversation)
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

    private func applyRename() {
        switch renaming {
        case .conversation(let id): store.rename(id, to: renameText)
        case .project(let id): store.renameProject(id, to: renameText)
        case nil: break
        }
        renaming = nil
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

/// Groups conversations by recency, like Messages or Mail.
private enum DateBucket: Int, CaseIterable {
    case today, yesterday, week, month, older

    var title: String {
        switch self {
        case .today: "Aujourd'hui"
        case .yesterday: "Hier"
        case .week: "7 derniers jours"
        case .month: "30 derniers jours"
        case .older: "Plus ancien"
        }
    }

    static func bucket(for date: Date, now: Date = .now, calendar: Calendar = .current) -> DateBucket {
        if calendar.isDateInToday(date) { return .today }
        if calendar.isDateInYesterday(date) { return .yesterday }
        let days = calendar.dateComponents([.day], from: date, to: now).day ?? 0
        if days < 7 { return .week }
        if days < 30 { return .month }
        return .older
    }

    static func group(_ conversations: [Conversation]) -> [(bucket: DateBucket, conversations: [Conversation])] {
        let grouped = Dictionary(grouping: conversations) { bucket(for: $0.updatedAt) }
        return allCases.compactMap { bucket in
            grouped[bucket].map { (bucket, $0) }
        }
    }
}
