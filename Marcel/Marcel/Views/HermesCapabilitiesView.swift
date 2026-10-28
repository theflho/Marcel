import SwiftUI

struct HermesCapabilitiesView: View {
    @Environment(ChatStore.self) private var store
    @State private var assistant = ""
    @State private var catalog: HermesCapabilities?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Picker("Profil Hermes", selection: $assistant) {
                    Text("Hermes").tag("")
                    ForEach(store.assistants) { Text($0.name).tag($0.id) }
                }
            } footer: {
                Text("Hermes choisit ses outils et ses skills selon ton message. Cette liste vient du profil sur le serveur ; elle indique ce qui est exposé, sans garantir qu’un service externe répondra.")
            }
            if let error { Text(error).foregroundStyle(.secondary) }
            if let catalog {
                if !catalog.ready {
                    Text("Ce profil est indisponible. Réessaie dans un instant ; la conversation reste dans ce profil.")
                        .foregroundStyle(.orange)
                }
                ForEach(catalog.issues, id: \.self) { Text($0).foregroundStyle(.orange) }
                Section("Outils") {
                    ForEach(catalog.toolsets, id: \.name) { group in
                        DisclosureGroup {
                            ForEach(group.tools, id: \.self) { Text($0).font(.caption.monospaced()) }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(group.label)
                                Text(group.enabled ? (group.configured ? "Activé · configuré" : "Configuration requise") : "Désactivé")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Skills") {
                    ForEach(catalog.skills, id: \.name) { skill in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(skill.name)
                            Text(skill.description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if catalog.skills.isEmpty { Text("Aucune skill listée.").foregroundStyle(.secondary) }
                }
            } else if error == nil { ProgressView() }
        }
        .navigationTitle("Outils et skills")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: assistant) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard !store.emergencyActive, let api = store.settings.api else { return }
        catalog = nil
        error = nil
        do {
            let result = try await api.hermesCapabilities(assistant: assistant.isEmpty ? nil : assistant)
            guard !Task.isCancelled else { return }
            catalog = result
        } catch { self.error = error.localizedDescription }
    }
}
