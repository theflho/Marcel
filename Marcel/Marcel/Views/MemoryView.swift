import SwiftUI

/// Marcel's memory on the active server: the core sent with every mission, the unlimited
/// archive, and the log of every change (each one can be undone).
struct MemoryView: View {
    @Environment(ChatStore.self) private var store
    @State private var stats: MemoryStats?
    @State private var facts: [MemoryFact] = []
    @State private var tier = "core"
    @State private var query = ""
    @State private var error: String?
    @State private var editing: MemoryFact?
    @State private var adding = false
    @State private var tidying = false
    @State private var tidyResult: String?
    @State private var actionError: String?

    var body: some View {
        Group {
            if store.emergencyActive {
                ContentUnavailableView("Arrêt d'urgence actif", systemImage: "exclamationmark.octagon",
                                       description: Text("Aucune requête n'est envoyée au serveur. Reprends pour consulter la mémoire."))
            } else if let error, stats == nil {
                ContentUnavailableView("Mémoire indisponible", systemImage: "wifi.exclamationmark",
                                       description: Text(error))
            } else {
                list
            }
        }
        .navigationTitle("Mémoire")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                NavigationLink {
                    MemoryLogView(onChange: { await load() })
                } label: {
                    Label("Historique", systemImage: "clock.arrow.circlepath")
                }
                Button("Ajouter un souvenir", systemImage: "plus") { adding = true }
            }
        }
        .searchable(text: $query, prompt: "Chercher dans la mémoire")
        .task(id: query) {
            // Wait for the user to stop typing before searching.
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            await load()
        }
        .sheet(item: $editing) { fact in
            MemoryEditor(fact: fact) { text, tier, pinned in
                await save(MemoryChange(text: text, tier: tier, pinned: pinned), for: fact)
            }
        }
        .sheet(isPresented: $adding) {
            MemoryEditor(fact: nil, initialTier: tier) { text, tier, pinned in
                await perform { api in
                    let fact = try await api.addMemory(text: text, tier: tier)
                    if pinned { _ = try await api.updateMemory(id: fact.id, MemoryChange(pinned: true)) }
                }
            }
        }
        .alert("Mémoire rangée", isPresented: .constant(tidyResult != nil)) {
            Button("OK") { tidyResult = nil }
        } message: {
            Text(tidyResult ?? "")
        }
        .memoryErrorAlert($actionError)
    }

    private var list: some View {
        List {
            if let stats, query.isEmpty {
                Section {
                    CoreGauge(stats: stats)
                    Button {
                        Task { await tidy() }
                    } label: {
                        HStack {
                            Label("Ranger maintenant", systemImage: "wand.and.stars")
                            Spacer()
                            if tidying { ProgressView() }
                        }
                    }
                    .disabled(tidying)
                } footer: {
                    Text(footer(stats))
                }

                Section {
                    Picker("Niveau", selection: $tier) {
                        Text("Noyau (\(stats.coreCount))").tag("core")
                        Text("Archives (\(stats.archiveCount))").tag("archive")
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }

            let shown = query.isEmpty ? facts.filter { $0.tier == tier } : facts
            Section {
                if shown.isEmpty {
                    Text(emptyText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(shown) { fact in
                    Button { editing = fact } label: {
                        FactRow(fact: fact, showTier: !query.isEmpty)
                    }
                    .tint(.primary)
                    .swipeActions(edge: .trailing) {
                        Button("Supprimer", systemImage: "trash", role: .destructive) {
                            Task { await perform { try await $0.deleteMemory(id: fact.id) } }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button(fact.isCore ? "Archiver" : "Noyau",
                               systemImage: fact.isCore ? "archivebox" : "star") {
                            Task { await save(MemoryChange(tier: fact.isCore ? "archive" : "core"), for: fact) }
                        }
                        .tint(fact.isCore ? .gray : .accentColor)
                        Button(fact.pinned ? "Détacher" : "Épingler",
                               systemImage: fact.pinned ? "pin.slash" : "pin") {
                            Task { await save(MemoryChange(pinned: !fact.pinned), for: fact) }
                        }
                        .tint(.orange)
                    }
                }
            } footer: {
                if query.isEmpty && !shown.isEmpty {
                    Text("Balaie vers la droite pour changer de niveau ou épingler, vers la gauche pour supprimer.")
                }
            }
        }
        .refreshable { await load() }
    }

    private var emptyText: String {
        if !query.isEmpty { return "Aucun souvenir ne correspond." }
        return tier == "core"
            ? "Le noyau est vide. Les souvenirs souvent utiles y montent tout seuls au rangement."
            : "Rien dans les archives. Marcel y range ce qu'il apprend dans vos conversations."
    }

    private func footer(_ stats: MemoryStats) -> String {
        var text = "Le noyau accompagne chaque mission ; les archives n'envoient que les souvenirs liés à la question. "
            + "Chaque nuit, Marcel fusionne les doublons, oublie ce qui a expiré et fait monter ou descendre les souvenirs selon leur usage."
        if let last = stats.lastTidy {
            text += " Dernier rangement : \(last.formatted(.relative(presentation: .named)))."
        }
        return text
    }

    // MARK: Actions

    private func load() async {
        guard !store.emergencyActive, let api = store.settings.api else { return }
        do {
            let result = try await api.memory(query: query.isEmpty ? nil : query)
            stats = result.stats
            facts = result.items
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save(_ change: MemoryChange, for fact: MemoryFact) async {
        await perform { _ = try await $0.updateMemory(id: fact.id, change) }
    }

    private func perform(_ action: (MarcelAPI) async throws -> Void) async {
        guard !store.emergencyActive, let api = store.settings.api else { return }
        do {
            try await action(api)
        } catch {
            actionError = error.localizedDescription
        }
        await load()
    }

    private func tidy() async {
        guard !store.emergencyActive, let api = store.settings.api else { return }
        tidying = true
        defer { tidying = false }
        do {
            let summary = try await api.tidyMemory()
            let changes = [
                (summary.merged, "fusionné"), (summary.expired, "oublié"),
                (summary.promoted, "monté au noyau"), (summary.demoted, "archivé"),
            ].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 > 1 ? "s" : "")" }
            tidyResult = changes.isEmpty ? "Rien à ranger, tout est en ordre." : changes.joined(separator: ", ").capitalizedFirst + "."
        } catch {
            actionError = error.localizedDescription
        }
        await load()
    }
}

private struct CoreGauge: View {
    let stats: MemoryStats

    private var share: Double { Double(stats.coreChars) / Double(max(stats.coreBudget, 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Noyau")
                    .font(.headline)
                Spacer()
                Text("\(Int((share * 100).rounded())) %")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(tint)
            }
            ProgressView(value: min(share, 1))
                .tint(tint)
            Text("\(stats.coreChars) / \(stats.coreBudget) caractères · \(stats.archiveCount) souvenir\(stats.archiveCount > 1 ? "s" : "") en archives")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        share < 0.6 ? .green : share < 0.9 ? .orange : .red
    }
}

private struct FactRow: View {
    let fact: MemoryFact
    let showTier: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(fact.text)
                .font(.body)
            HStack(spacing: 8) {
                if fact.pinned {
                    Image(systemName: "pin.fill").foregroundStyle(.orange)
                }
                if showTier {
                    Text(fact.isCore ? "Noyau" : "Archives")
                }
                if let used = fact.lastUsedAt, fact.uses > 0 {
                    Text("Utilisé \(fact.uses) fois · \(used.formatted(.relative(presentation: .named)))")
                } else {
                    Text("Jamais utilisé")
                }
                if let expires = fact.expiresAt {
                    Label(expires.formatted(.dateTime.day().month()), systemImage: "hourglass")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Adds a fact, or edits one.
private struct MemoryEditor: View {
    let fact: MemoryFact?
    var initialTier = "archive"
    let onSave: (String, String, Bool) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var tier = "archive"
    @State private var pinned = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Ce que Marcel doit retenir", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                } footer: {
                    Text("\(text.count) / 300 caractères")
                }
                Section {
                    Picker("Niveau", selection: $tier) {
                        Text("Noyau").tag("core")
                        Text("Archives").tag("archive")
                    }
                    Toggle("Épinglé", isOn: $pinned)
                } footer: {
                    Text("Un souvenir épinglé reste toujours au noyau : le rangement ne le déplace ni ne l'oublie.")
                }
                if let fact {
                    Section {
                        LabeledContent("Appris", value: fact.createdAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Origine", value: fact.source == "manuel" ? "Ajouté à la main"
                                       : fact.source == "import" ? "Importé" : "Conversation")
                        LabeledContent("Utilisations", value: "\(fact.uses)")
                    }
                }
            }
            .navigationTitle(fact == nil ? "Nouveau souvenir" : "Souvenir")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        saving = true
                        Task {
                            await onSave(text.trimmingCharacters(in: .whitespacesAndNewlines), tier, pinned)
                            dismiss()
                        }
                    }
                    .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || text.count > 300)
                }
            }
            .onAppear {
                text = fact?.text ?? ""
                tier = fact?.tier ?? initialTier
                pinned = fact?.pinned ?? false
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Every change to the memory, newest first. Undoing a tidying run or an import undoes all of it.
private struct MemoryLogView: View {
    let onChange: () async -> Void

    @Environment(ChatStore.self) private var store
    @State private var entries: [MemoryLogEntry] = []
    @State private var actionError: String?

    var body: some View {
        List(entries) { entry in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: icon(entry.action))
                        .foregroundStyle(entry.undone ? Color.secondary : Color.accentColor)
                    Text(title(entry.action))
                        .font(.subheadline.weight(.semibold))
                    if let batch = entry.batch {
                        Text(batch.hasPrefix("import") ? "Import" : "Rangement")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: .capsule)
                    }
                    Spacer()
                    Text(entry.at, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let before = entry.before, let after = entry.after, before != after {
                    Text(before).strikethrough().foregroundStyle(.secondary)
                    Text(after)
                } else {
                    Text(entry.after ?? entry.before ?? "")
                }
                if !entry.reason.isEmpty || entry.undone {
                    Text(entry.undone ? "Annulé" : entry.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .opacity(entry.undone ? 0.5 : 1)
            .swipeActions {
                if !entry.undone {
                    Button(entry.batch == nil ? "Annuler" : "Annuler le lot", systemImage: "arrow.uturn.backward") {
                        Task { await undo(entry) }
                    }
                    .tint(.orange)
                }
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("Aucun changement", systemImage: "clock",
                                       description: Text("Chaque souvenir appris, rangé ou supprimé apparaîtra ici."))
            }
        }
        .navigationTitle("Historique")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .memoryErrorAlert($actionError)
    }

    private func load() async {
        guard !store.emergencyActive, let api = store.settings.api else { return }
        do { entries = try await api.memoryLog() } catch { actionError = error.localizedDescription }
    }

    private func undo(_ entry: MemoryLogEntry) async {
        guard !store.emergencyActive, let api = store.settings.api else { return }
        do { try await api.undoMemory(entryID: entry.id) } catch { actionError = error.localizedDescription }
        await load()
        await onChange()
    }

    private func title(_ action: String) -> String {
        switch action {
        case "add": "Appris"
        case "edit": "Modifié"
        case "promote": "Monté au noyau"
        case "demote": "Archivé"
        case "merge": "Fusionné"
        case "expire": "Oublié"
        case "delete": "Supprimé"
        default: action
        }
    }

    private func icon(_ action: String) -> String {
        switch action {
        case "add": "plus.circle"
        case "edit": "pencil"
        case "promote": "arrow.up.circle"
        case "demote": "archivebox"
        case "merge": "arrow.triangle.merge"
        case "expire": "hourglass"
        case "delete": "trash"
        default: "circle"
        }
    }
}

private extension View {
    func memoryErrorAlert(_ message: Binding<String?>) -> some View {
        alert("Échec", isPresented: .constant(message.wrappedValue != nil)) {
            Button("OK") { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
