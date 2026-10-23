import SwiftUI

/// What the user wants to accomplish and Marcel follows, on the active server.
/// Marcel proposes goals it spots in conversations; nothing is followed without the user's yes.
struct GoalsView: View {
    @Environment(ChatStore.self) private var store
    @State private var goals: [Goal] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var editing: Goal?
    @State private var adding = false
    @State private var actionError: String?
    @State private var notice: String?

    var body: some View {
        Group {
            if store.emergencyActive {
                ContentUnavailableView("Arrêt d'urgence actif", systemImage: "exclamationmark.octagon",
                                       description: Text("Aucune requête n'est envoyée au serveur. Reprends pour consulter les objectifs."))
            } else if let error, goals.isEmpty {
                ContentUnavailableView("Objectifs indisponibles", systemImage: "wifi.exclamationmark",
                                       description: Text(error))
            } else if loaded && goals.isEmpty {
                ContentUnavailableView("Aucun objectif", systemImage: "scope",
                                       description: Text("Dis à Marcel ce que tu cherches ou veux accomplir : il te proposera de le suivre."))
            } else {
                list
            }
        }
        .navigationTitle("Objectifs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Ajouter un objectif", systemImage: "plus") { adding = true }
                    .disabled(store.emergencyActive)
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editing) { goal in
            GoalEditor(goal: goal) { title, detail, cadence in
                await perform { _ = try await $0.updateGoal(id: goal.id, GoalChange(title: title, detail: detail, cadence: cadence)) }
            }
        }
        .sheet(isPresented: $adding) {
            GoalEditor(goal: nil) { title, detail, cadence in
                await perform { _ = try await $0.addGoal(title: title, detail: detail, cadence: cadence) }
            }
        }
        .alert("Échec", isPresented: .constant(actionError != nil)) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .alert("Vérification lancée", isPresented: .constant(notice != nil)) {
            Button("OK") { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    private var list: some View {
        List {
            section("Proposés par Marcel", status: "proposed",
                    footer: "Repérés dans tes conversations. Rien n'est suivi sans ton accord.")
            section("Suivis", status: "active",
                    footer: "Marcel connaît ces objectifs dans chaque conversation et les vérifie de lui-même au rythme choisi. Ce qui vaut la peine arrive dans Idées.")
            section("En pause", status: "paused")
            section("Terminés", status: "done")
        }
    }

    @ViewBuilder
    private func section(_ title: String, status: String, footer: String? = nil) -> some View {
        let matching = goals.filter { $0.status == status }
        if !matching.isEmpty {
            Section {
                ForEach(matching) { goal in
                    row(goal)
                }
            } header: {
                Text(title)
            } footer: {
                if let footer { Text(footer) }
            }
        }
    }

    private func row(_ goal: Goal) -> some View {
        Button {
            editing = goal
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                GoalSummary(goal: goal)
                if goal.status == "proposed" {
                    HStack {
                        Button("Suivre") { Task { await setStatus("active", of: goal) } }
                            .buttonStyle(.borderedProminent)
                        Button("Non merci") { Task { await setStatus("dismissed", of: goal) } }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
            }
        }
        .tint(.primary)
        .swipeActions(edge: .leading) {
            switch goal.status {
            case "active":
                Button("Vérifier", systemImage: "arrow.clockwise") { Task { await check(goal) } }
                    .tint(.blue)
                Button("Pause", systemImage: "pause.fill") { Task { await setStatus("paused", of: goal) } }
                    .tint(.orange)
                Button("Terminé", systemImage: "checkmark") { Task { await setStatus("done", of: goal) } }
                    .tint(.green)
            case "paused", "done":
                Button("Suivre", systemImage: "play.fill") { Task { await setStatus("active", of: goal) } }
                    .tint(.accentColor)
            default:
                EmptyView()
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Supprimer", systemImage: "trash", role: .destructive) {
                Task { await perform { try await $0.deleteGoal(id: goal.id) } }
            }
        }
    }

    private func setStatus(_ status: String, of goal: Goal) async {
        await perform { _ = try await $0.updateGoal(id: goal.id, GoalChange(status: status)) }
        // Keep the conversation's proposal card in step with what was decided here.
        await store.refreshGoalProposals()
    }

    private func check(_ goal: Goal) async {
        guard !store.emergencyActive, let api = store.settings.api else { return }
        do {
            _ = try await api.checkGoal(id: goal.id)
            notice = "Marcel regarde où en est « \(goal.title) ». S'il trouve quelque chose qui vaut la peine, ce sera dans Idées."
        } catch {
            actionError = error.localizedDescription
        }
        await load()
    }

    private func load() async {
        guard !store.emergencyActive, let api = store.settings.api else { return }
        do {
            goals = try await api.goals()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
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
}

/// Title, detail and rhythm of a goal.
struct GoalSummary: View {
    let goal: Goal

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(goal.title)
                .font(.body.weight(.medium))
            if !goal.detail.isEmpty {
                Text(goal.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 10) {
                Label(Goal.cadenceLabel(goal.cadence), systemImage: "arrow.clockwise")
                if goal.status == "active", let lastRunAt = goal.lastRunAt {
                    Label {
                        Text("vérifié \(lastRunAt, format: .relative(presentation: .named))")
                    } icon: {
                        Image(systemName: "checkmark.circle")
                    }
                }
            }
            .labelStyle(.compact)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

extension Goal {
    static let cadences = ["daily", "weekly", "manual"]

    static func cadenceLabel(_ cadence: String) -> String {
        switch cadence {
        case "daily": "Chaque jour"
        case "manual": "Seulement quand je demande"
        default: "Chaque semaine"
        }
    }
}

/// Proposal shown above the composer when Marcel spotted a goal in this conversation.
struct GoalProposalCard: View {
    @Environment(ChatStore.self) private var store
    let goal: Goal

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Marcel peut suivre ça pour toi", systemImage: "scope")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            GoalSummary(goal: goal)
            HStack {
                Button("Suivre") { Task { await store.answer(goal, follow: true) } }
                    .buttonStyle(.borderedProminent)
                Button("Non merci") { Task { await store.answer(goal, follow: false) } }
                    .buttonStyle(.bordered)
                Spacer()
                if store.goalProposals.count > 1 {
                    Text("+\(store.goalProposals.count - 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18).strokeBorder(Color.accentColor.opacity(0.35))
        }
        .padding(.horizontal)
        .accessibilityElement(children: .contain)
    }
}

private struct GoalEditor: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let goal: Goal?
    let onSave: (String, String, String) async -> Void
    @State private var title = ""
    @State private var detail = ""
    @State private var cadence = "weekly"
    @State private var saving = false
    @State private var checks: [GoalCheck] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Ex. Trouver un Mac mini", text: $title)
                    TextField("Détails : budget, contraintes, échéance…", text: $detail, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text("Objectif")
                }
                Section {
                    Picker("Rythme", selection: $cadence) {
                        ForEach(Goal.cadences, id: \.self) { Text(Goal.cadenceLabel($0)).tag($0) }
                    }
                } footer: {
                    Text("À quelle fréquence Marcel vérifie de lui-même où ça en est.")
                }
                if !checks.isEmpty {
                    Section("Dernières vérifications") {
                        ForEach(checks) { check in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(Self.decisionLabel(check.decision))
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    Text(check.at, format: .relative(presentation: .named))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if !check.summary.isEmpty {
                                    Text(check.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(goal == nil ? "Nouvel objectif" : "Modifier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        saving = true
                        Task {
                            await onSave(title.trimmingCharacters(in: .whitespacesAndNewlines),
                                         detail.trimmingCharacters(in: .whitespacesAndNewlines), cadence)
                            dismiss()
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).count < 3 || saving)
                }
            }
            .onAppear {
                guard let goal else { return }
                title = goal.title
                detail = goal.detail
                cadence = goal.cadence
            }
            .task {
                guard let goal, !store.emergencyActive, let api = store.settings.api else { return }
                checks = (try? await api.goalChecks(id: goal.id)) ?? []
            }
        }
        .presentationDetents([.medium, .large])
    }
}

extension GoalEditor {
    static func decisionLabel(_ decision: String) -> String {
        switch decision {
        case "notify": "Idée proposée"
        case "later": "Gardé pour plus tard"
        case "nothing": "Rien de nouveau"
        default: "Échec"
        }
    }
}

/// Icon and title close together, for small captions inside list rows.
private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

private extension LabelStyle where Self == CompactLabelStyle {
    static var compact: CompactLabelStyle { CompactLabelStyle() }
}
