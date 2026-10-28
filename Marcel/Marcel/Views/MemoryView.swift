import SwiftUI

/// Read-only legacy data. Active memory lives in the Hermes profile.
struct MemoryView: View {
    @Environment(ChatStore.self) private var store
    @State private var facts: [MemoryFact] = []
    @State private var query = ""
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                Text("La mémoire active est celle de ton profil Hermes. Demande-lui dans la conversation ce qu’il retient ou ce qu’il doit corriger.")
                Text("Ces anciens souvenirs sont conservés pour consultation. Ils ne sont plus envoyés à Hermes.")
                    .foregroundStyle(.secondary)
            }
            Section("Archives") {
                if let error {
                    Text(error).foregroundStyle(.secondary)
                } else if !loaded {
                    ProgressView()
                } else if facts.isEmpty {
                    Text("Aucun ancien souvenir.").foregroundStyle(.secondary)
                }
                ForEach(facts) { fact in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fact.text)
                        if let owner = fact.owner, !owner.isEmpty {
                            Text(store.assistants.first { $0.id == owner }?.name ?? owner)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Anciens souvenirs")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Chercher dans les archives")
        .task(id: query) {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await load()
        }
        .refreshable { await load() }
    }

    private func load() async {
        guard !store.emergencyActive, let api = store.settings.api else { return }
        do {
            let result = try await api.memory(query: query.isEmpty ? nil : query)
            guard !Task.isCancelled else { return }
            facts = result.items
            loaded = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
