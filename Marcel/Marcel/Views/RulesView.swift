import SwiftUI

/// What Marcel may do by himself, what waits for "Valider" and what he must not do, one kind of
/// action at a time (like Grok Bot's Always allow / Needs approval / Blocked: start strict, loosen as
/// trust grows). A bot can have its own level, set in its card. Some limits never move.
struct RulesView: View {
    @Environment(ChatStore.self) private var store
    @State private var rules: ActionRules?
    @State private var error: String?
    @State private var newWord = ""

    private static let order = ["reglage", "assistant", "objectif", "routine", "recette", "navigateur", "recherche",
                                "iphone", "iphone_ecriture"]

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
                    Text("« Tout seul » : Marcel le fait et te montre « Annuler ». « Demander » : il te le propose et attend « Valider ». « Bloqué » : il ne le fait pas. Un bot peut avoir ses propres règles, dans sa fiche.")
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
                    Text("Mots privés")
                } footer: {
                    Text("Une recherche web d'un bot qui contient l'un de ces mots, une adresse, un e-mail ou un téléphone est bloquée avant de partir. Les noms que Marcel retient sur toi comptent aussi. Le chercheur, lui, ne reçoit que la question : il ne sait rien de toi.")
                }
            } else if let error {
                Text(error).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            Section {
                Label("Jamais supprimer ni épingler", systemImage: "lock")
                Label("Jamais tes mots de passe ni tes cartes", systemImage: "lock")
                Label("Jamais tout seul si un e-mail ou un fichier est en jeu", systemImage: "lock")
                Label("Jamais d'envoi d'e-mail : brouillon seulement", systemImage: "lock")
            } header: {
                Text("Toujours")
            } footer: {
                Text("Ces limites-là ne se règlent pas : le serveur les applique quoi que dise le modèle.")
            }
            .foregroundStyle(.secondary)
        }
        .navigationTitle("Règles")
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

    private static let kinds = ["reglage", "routine", "recette", "recherche", "iphone", "iphone_ecriture"]

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
