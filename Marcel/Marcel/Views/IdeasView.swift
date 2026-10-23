import SwiftUI

/// What Marcel found by itself while checking the followed goals, on the active server.
/// Marcel only proposes: opening an idea starts a conversation, and a prepared action happens
/// only once the user approves it after seeing exactly what will be sent.
struct IdeasView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var ideas: [Idea] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var actionError: String?
    @State private var approving: Idea?

    var body: some View {
        Group {
            if store.emergencyActive {
                ContentUnavailableView("Arrêt d'urgence actif", systemImage: "exclamationmark.octagon",
                                       description: Text("Aucune requête n'est envoyée au serveur, et Marcel ne vérifie plus rien."))
            } else if let error, ideas.isEmpty {
                ContentUnavailableView("Idées indisponibles", systemImage: "wifi.exclamationmark",
                                       description: Text(error))
            } else if loaded && ideas.isEmpty {
                ContentUnavailableView("Aucune idée pour l'instant", systemImage: "lightbulb",
                                       description: Text("Marcel vérifie tes objectifs suivis à leur rythme et te prévient ici quand il trouve quelque chose d'utile."))
            } else {
                list
            }
        }
        .navigationTitle("Idées")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    ProactiveSettingsView()
                } label: {
                    Label("Proactivité", systemImage: "slider.horizontal.3")
                }
                .disabled(store.emergencyActive)
            }
        }
        .task {
            await load()
            // Statuses stay as loaded here, so new ideas keep standing out while the list is open.
            await store.markIdeasSeen()
        }
        .refreshable { await load() }
        .sheet(item: $approving) { idea in
            ApprovalSheet(idea: idea) {
                approving = nil
                Task {
                    await store.approve(idea)
                    dismiss()
                }
            }
        }
        .alert("Échec", isPresented: .constant(actionError != nil)) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    private var list: some View {
        List {
            section("Nouvelles", status: "new")
            section("À voir", status: "seen")
            section("Ouvertes", status: "opened")
            section("Validées", status: "approved",
                    footer: "Rien n'est envoyé, réservé ni acheté sans ta validation, après avoir vu ce qui part.")
        }
    }

    @ViewBuilder
    private func section(_ title: String, status: String, footer: String? = nil) -> some View {
        let matching = ideas.filter { $0.status == status }
        if !matching.isEmpty {
            Section {
                ForEach(matching) { idea in
                    IdeaCard(idea: idea, isNew: status == "new", canApprove: !store.emergencyActive) {
                        Task {
                            await store.open(idea)
                            dismiss()
                        }
                    } onApprove: {
                        approving = idea
                    } onDismiss: {
                        Task { await perform { _ = try await $0.updateIdea(id: idea.id, status: "dismissed") } }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Supprimer", systemImage: "trash", role: .destructive) {
                            Task { await perform { try await $0.deleteIdea(id: idea.id) } }
                        }
                    }
                }
            } header: {
                Text(title)
            } footer: {
                if let footer { Text(footer) }
            }
        }
    }

    private func load() async {
        guard !store.emergencyActive, let api = store.settings.api else { return }
        do {
            ideas = try await api.ideas()
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

/// One idea: the goal it comes from, what Marcel found, and the action it prepared, if any.
private struct IdeaCard: View {
    let idea: Idea
    let isNew: Bool
    let canApprove: Bool
    let onOpen: () -> Void
    let onApprove: () -> Void
    let onDismiss: () -> Void

    private var isDone: Bool { idea.status == "opened" || idea.status == "approved" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if isNew {
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                        .accessibilityLabel("Nouvelle")
                }
                Label(idea.goalTitle, systemImage: "scope")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(idea.createdAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(idea.title)
                .font(.body.weight(.medium))
            if !idea.body.isEmpty {
                Text(idea.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !idea.action.isEmpty {
                Label {
                    Text(idea.status == "approved" ? "Validé : \(idea.action)" : "Préparé, attend ton accord : \(idea.action)")
                } icon: {
                    Image(systemName: idea.status == "approved" ? "checkmark.seal" : "hand.raised")
                }
                .font(.caption)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: .rect(cornerRadius: 10))
            }
            HStack {
                if !idea.action.isEmpty && idea.status != "approved" {
                    Button("Valider…", action: onApprove)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canApprove)
                    Button(isDone ? "Reprendre" : "Ouvrir", action: onOpen)
                        .buttonStyle(.bordered)
                } else {
                    Button(isDone ? "Reprendre" : "Ouvrir", action: onOpen)
                        .buttonStyle(.borderedProminent)
                }
                if !isDone {
                    Button("Pas intéressé", action: onDismiss)
                        .buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

/// Shows exactly what will be sent before the user lets Marcel act, like a "send" preview.
private struct ApprovalSheet: View {
    @Environment(\.dismiss) private var dismiss
    let idea: Idea
    let onConfirm: () -> Void

    private var detail: String? {
        guard let detail = idea.actionDetail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty else { return nil }
        return detail
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(idea.goalTitle, systemImage: "scope")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(idea.action)
                            .font(.title3.weight(.semibold))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ce qui va partir")
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                        if let detail {
                            Text(detail)
                                .font(.callout)
                                .textSelection(.enabled)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.surface, in: .rect(cornerRadius: 12))
                        } else {
                            Label("Marcel n'a pas précisé le texte exact : il te le montrera et attendra ton accord avant d'envoyer quoi que ce soit.",
                                  systemImage: "info.circle")
                                .font(.callout)
                        }
                    }
                    Label("Marcel le fait dans une conversation, où tu suis chaque étape. Si quelque chose a changé (prix, disponibilité, destinataire), il s'arrête et t'explique.",
                          systemImage: "checkmark.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onConfirm()
                } label: {
                    Text(detail == nil ? "Valider" : "Valider et envoyer")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
                .background(.bar)
            }
            .navigationTitle("Valider l'action")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// How proactive Marcel is on the active server, and how much it may spend on checks.
struct ProactiveSettingsView: View {
    @Environment(ChatStore.self) private var store
    @State private var settings: ProactiveSettings?
    @State private var error: String?

    var body: some View {
        Form {
            if let settings {
                Section {
                    Picker("Proactivité", selection: levelBinding) {
                        Text("Désactivée").tag("off")
                        Text("Discrète").tag("quiet")
                        Text("Normale").tag("normal")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Marcel proactif")
                } footer: {
                    Text(Self.levelFooter(settings.level))
                }
                if settings.level == "normal" {
                    Section {
                        Stepper(value: dailyLimitBinding, in: 1...10) {
                            LabeledContent("Idées par jour, au plus", value: "\(settings.dailyLimit)")
                        }
                    } footer: {
                        Text("Au-delà, Marcel garde ce qu'il trouve pour plus tard au lieu de te déranger.")
                    }
                }
                Section {
                    Stepper(value: maxChecksBinding, in: 0...50) {
                        LabeledContent("Vérifications par jour, au plus", value: "\(settings.maxChecksPerDay)")
                    }
                    LabeledContent("Aujourd'hui", value: "\(settings.checksToday) vérif. · \(settings.ideasToday) idée(s)")
                    if let tokens = settings.tokensToday, let budget = settings.tokenBudget, budget > 0 {
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("Tokens du jour",
                                           value: "\(tokens.formatted()) / \(budget.formatted())")
                            ProgressView(value: min(Double(tokens), Double(budget)), total: Double(budget))
                                .tint(tokens >= budget ? .red : .accentColor)
                        }
                    }
                } header: {
                    Text("Coût")
                } footer: {
                    Text("Chaque vérification est une mission de Marcel sur le serveur : ce plafond limite la dépense. "
                         + "Les vérifications automatiques ont lieu entre \(Self.hours(settings.hours)) (heure du serveur) "
                         + "et jamais pendant un arrêt d'urgence.")
                }
            } else if let error {
                ContentUnavailableView("Réglages indisponibles", systemImage: "wifi.exclamationmark",
                                       description: Text(error))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Proactivité")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(store.emergencyActive)
        .task { await load() }
    }

    // Each setting changes here at once, then on the server (which answers with the truth).

    private var levelBinding: Binding<String> {
        Binding(get: { settings?.level ?? "normal" }, set: { value in
            settings?.level = value
            Task { await save(ProactiveChange(level: value)) }
        })
    }

    private var dailyLimitBinding: Binding<Int> {
        Binding(get: { settings?.dailyLimit ?? 2 }, set: { value in
            settings?.dailyLimit = value
            Task { await save(ProactiveChange(dailyLimit: value)) }
        })
    }

    private var maxChecksBinding: Binding<Int> {
        Binding(get: { settings?.maxChecksPerDay ?? 6 }, set: { value in
            settings?.maxChecksPerDay = value
            Task { await save(ProactiveChange(maxChecksPerDay: value)) }
        })
    }

    private func load() async {
        guard !store.emergencyActive, let api = store.settings.api else { return }
        do {
            settings = try await api.proactive()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save(_ change: ProactiveChange) async {
        guard !store.emergencyActive, let api = store.settings.api else { return }
        do {
            settings = try await api.updateProactive(change)
        } catch {
            self.error = error.localizedDescription
            await load()
        }
    }

    private static func levelFooter(_ level: String) -> String {
        switch level {
        case "off": "Marcel ne vérifie plus rien de lui-même. Tu peux toujours lancer une vérification depuis Objectifs."
        case "quiet": "Marcel vérifie tes objectifs mais ne te prévient que pour l'important, une fois par jour au plus."
        default: "Marcel vérifie tes objectifs à leur rythme et te propose une idée quand il trouve du nouveau."
        }
    }

    private static func hours(_ hours: [Int]) -> String {
        guard hours.count == 2, hours != [0, 24] else { return "0 h et 24 h" }
        return "\(hours[0]) h et \(hours[1]) h"
    }
}
