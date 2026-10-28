import SwiftUI

/// What Marcel may do by himself, what waits for "Valider" and what he must not do, one kind of
/// action at a time (like Grok Bot's Always allow / Needs approval / Blocked: start strict, loosen as
/// trust grows). A bot can have its own level, set in its card. Some limits never move.
struct RulesView: View {
    @Environment(ChatStore.self) private var store
    @State private var rules: ActionRules?
    @State private var error: String?
    @State private var newWord = ""

    private static let order = ["reglage", "assistant", "objectif", "routine", "recette", "compte", "achat",
                                "iphone", "iphone_ecriture"]
    private static let caps = [0, 20, 50, 100, 200, 500]

    var body: some View {
        List {
            if let rules {
                Section {
                    ForEach(Self.order.filter { rules.labels[$0] != nil }, id: \.self) { kind in
                        Picker(rules.labels[kind] ?? kind, selection: binding(kind)) {
                            ForEach(RuleLevel.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                    }
                } footer: {
                    Text("Ces autorisations concernent les données et actions de l’app. Hermes choisit ses outils et skills de sa propre initiative, sans commande spéciale ni permission générale de navigation. Ses validations natives restent applicables. Un profil de bot peut avoir ses propres règles.")
                }
                Section {
                    Picker("Plafond par achat", selection: capBinding) {
                        ForEach(Self.caps, id: \.self) { Text($0 == 0 ? "Rien seul" : "\($0) €").tag($0) }
                    }
                    if let mailbox = rules.mailbox {
                        LabeledContent("Son adresse", value: mailbox)
                    }
                } header: {
                    Text("Comptes et achats")
                } footer: {
                    Text("Hermes crée ses comptes avec sa propre adresse et ses identifiants, rangés dans le coffre de son navigateur. Pour payer, mets-y une carte virtuelle plafonnée, jamais ta vraie carte : ce plafond-là, la banque l'applique quoi qu'il arrive.")
                }
                Section {
                    ForEach(rules.privateWords ?? [], id: \.self) { word in
                        Text(word)
                            .swipeActions {
                                Button("Retirer", systemImage: "minus.circle", role: .destructive) {
                                    Task { await saveWords((rules.privateWords ?? []).filter { $0 != word }) }
                                }
                            }
                    }
                    HStack {
                        TextField("Ton nom, ta ville, ton employeur…", text: $newWord)
                            .autocorrectionDisabled()
                            .onSubmit(addWord)
                        Button("Ajouter", action: addWord)
                            .disabled(newWord.trimmingCharacters(in: .whitespaces).count < 3)
                    }
                } header: {
                    Text("Recherche isolée (compatibilité)")
                } footer: {
                    Text("Ces mots filtrent uniquement l’ancien circuit de recherche isolée de l’app. Ils ne filtrent pas les outils web natifs de Hermes.")
                }
            } else if let error {
                Text(error).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            Section {
                Label("Jamais supprimer ni épingler", systemImage: "lock")
                Label("Jamais tes mots de passe ni ta vraie carte : son identité à lui", systemImage: "lock")
                Label("E-mails lus dans le profil protégé", systemImage: "lock")
                Label("Jamais d'envoi d'e-mail : brouillon seulement", systemImage: "lock")
            } header: {
                Text("Toujours")
            } footer: {
                Text("Les protections de l’app et les consignes de Hermes restent en place : arrêt d’urgence, budgets, e-mails protégés et coffre.")
            }
            .foregroundStyle(.secondary)
        }
        .navigationTitle("Autorisations de l’app")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func binding(_ kind: String) -> Binding<String> {
        Binding {
            rules?.rules[kind] ?? "auto"
        } set: { value in
            rules?.rules[kind] = value
            Task { await save([kind: value]) }
        }
    }

    private var capBinding: Binding<Int> {
        Binding {
            rules?.purchaseCap ?? 50
        } set: { value in
            rules?.purchaseCap = value
            Task {
                guard let api = store.settings.api else { return }
                do {
                    rules = try await api.setRules([:], purchaseCap: value)
                } catch {
                    self.error = "Pas enregistré : \(error.localizedDescription)"
                    await load()
                }
            }
        }
    }

    private func load() async {
        guard !store.emergencyActive, let api = store.settings.api else { return }
        do {
            rules = try await api.rules()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func addWord() {
        let word = newWord.trimmingCharacters(in: .whitespaces)
        guard word.count >= 3 else { return }
        newWord = ""
        Task { await saveWords((rules?.privateWords ?? []) + [word]) }
    }

    private func saveWords(_ words: [String]) async {
        guard let api = store.settings.api else { return }
        do {
            rules = try await api.setRules([:], privateWords: words)
        } catch {
            self.error = "Pas enregistré : \(error.localizedDescription)"
            await load()
        }
    }

    private func save(_ change: [String: String]) async {
        guard let api = store.settings.api else { return }
        do {
            rules = try await api.setRules(change)
        } catch {
            self.error = "Pas enregistré : \(error.localizedDescription)"
            await load()
        }
    }
}

/// Grok Bot's three levels, in Marcel's words.
enum RuleLevel: String, CaseIterable, Identifiable {
    case auto, ask, off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Tout seul"
        case .ask: "Demander"
        case .off: "Bloqué"
        }
    }
}

/// A bot's own levels in its card, for what a bot can do: like Grok Bot's per-bot permissions.
/// "Comme partout" follows Réglages › Règles.
struct BotRulesSection: View {
    @Environment(ChatStore.self) private var store
    let assistantID: String
    @State private var rules: ActionRules?

    private static let kinds = ["reglage", "routine", "recette", "compte", "achat", "iphone",
                                "iphone_ecriture"]

    var body: some View {
        Section {
            if let rules {
                ForEach(Self.kinds.filter { rules.labels[$0] != nil }, id: \.self) { kind in
                    Picker(rules.labels[kind] ?? kind, selection: binding(kind)) {
                        let general = RuleLevel(rawValue: rules.rules[kind] ?? "auto")?.label ?? ""
                        Text("Comme partout (\(general.lowercased()))").tag("")
                        ForEach(RuleLevel.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                }
            } else {
                ProgressView()
            }
        } header: {
            Text("Ce qu'il peut faire")
        } footer: {
            Text("« Comme partout » suit Réglages › Règles. Le reste ne vaut que pour ce bot.")
        }
        .task { rules = try? await store.settings.api?.rules() }
    }

    private func binding(_ kind: String) -> Binding<String> {
        Binding {
            rules?.bots?[assistantID]?[kind] ?? ""
        } set: { value in
            rules?.bots?[assistantID, default: [:]][kind] = value
            Task {
                guard let api = store.settings.api else { return }
                rules = (try? await api.setRules([kind: value], assistant: assistantID)) ?? rules
            }
        }
    }
}
