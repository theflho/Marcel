import SwiftUI

/// What Marcel may do by himself and what waits for "Valider", one kind of action at a time (like
/// ChatGPT's dots: start strict, loosen as trust grows). Some limits never move.
struct RulesView: View {
    @Environment(ChatStore.self) private var store
    @State private var rules: ActionRules?
    @State private var error: String?
    @State private var newWord = ""

    private static let order = ["reglage", "assistant", "objectif", "routine", "navigateur", "recherche"]

    var body: some View {
        List {
            if let rules {
                Section {
                    ForEach(Self.order.filter { rules.labels[$0] != nil }, id: \.self) { kind in
                        Picker(rules.labels[kind] ?? kind, selection: binding(kind)) {
                            Text("Tout seul").tag("auto")
                            Text("Demander").tag("ask")
                        }
                    }
                } footer: {
                    Text("« Tout seul » : Marcel le fait et te montre « Annuler ». « Demander » : il te le propose et attend « Valider ».")
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
