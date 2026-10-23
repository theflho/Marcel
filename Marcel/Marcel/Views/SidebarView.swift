import SwiftUI

/// Side drawer: search, projects and recent conversations.
struct SidebarView: View {
    @Environment(ChatStore.self) private var store
    var onClose: () -> Void
    var onOpenSettings: () -> Void

    @State private var query = ""
    @State private var expandedProjects: Set<UUID> = []
    @State private var renaming: RenameTarget?
    @State private var renameText = ""
    @State private var creatingProject = false
    @State private var newProjectName = ""
    @State private var confirmingEmergency = false

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
                    projectsSection
                    ForEach(DateBucket.group(store.listedConversations.filter { $0.projectID == nil }), id: \.bucket) { group in
                        Section(group.bucket.title) {
                            ForEach(group.conversations) { row(for: $0) }
                        }
                    }
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
        VStack(spacing: 12) {
            HStack {
                Text("Marcel")
                    .font(.title2.weight(.bold))
                Spacer()
                Button {
                    store.newConversation()
                    onClose()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 40, height: 40)
                        .background(Theme.surface, in: .circle)
                }
                .tint(.primary)
                .accessibilityLabel("Nouvelle conversation")
            }
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
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var projectsSection: some View {
        Section {
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
            Text("Projets")
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
        HStack {
            Button {
                onOpenSettings()
            } label: {
                Label("Réglages", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .tint(.primary)
            if !store.emergencyActive {
                Button("Arrêt d'urgence", systemImage: "exclamationmark.octagon.fill") { confirmingEmergency = true }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 22))
                    .foregroundStyle(.red)
                    .frame(width: 44, height: 44)
                    .padding(.trailing, 8)
            }
        }
        .background(.bar)
        .emergencyConfirmation(isPresented: $confirmingEmergency)
    }

    // MARK: Rows

    private func row(for conversation: Conversation) -> some View {
        Button {
            store.select(conversation.id)
            onClose()
        } label: {
            HStack(spacing: 10) {
                MarcelAvatar(size: 36, mood: conversation.displayMood)
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .font(.body.weight(conversation.id == store.currentID ? .semibold : .regular))
                        .lineLimit(1)
                    if let last = conversation.messages.last(where: { !$0.content.isEmpty }) {
                        Text(Self.preview(last.content))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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
        conversation.messages
            .map { "\($0.role == .user ? "Moi" : "Marcel") : \($0.content)" }
            .joined(separator: "\n\n")
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
