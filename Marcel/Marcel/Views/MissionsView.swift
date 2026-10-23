import SwiftUI

/// Every mission on the active server: what's running now and what was delivered.
struct MissionsView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var missions: [MissionInfo] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if store.emergencyActive {
                    ContentUnavailableView("Arrêt d'urgence actif", systemImage: "exclamationmark.octagon",
                                           description: Text("Aucune requête n'est envoyée au serveur. Reprends depuis le bandeau ou les réglages."))
                } else if let error, missions.isEmpty {
                    ContentUnavailableView("Missions indisponibles", systemImage: "wifi.exclamationmark",
                                           description: Text(error))
                } else if loaded && missions.isEmpty {
                    ContentUnavailableView("Aucune mission", systemImage: "checklist",
                                           description: Text("Les réponses de Marcel apparaîtront ici, même quand l'app est fermée."))
                } else {
                    list
                }
            }
            .navigationTitle("Missions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .task {
                // Refresh while the sheet is open; faster when something is running.
                while !Task.isCancelled {
                    await refresh()
                    let running = missions.contains { $0.status == "running" }
                    try? await Task.sleep(for: .seconds(running ? 2 : 10))
                }
            }
        }
    }

    private var list: some View {
        List {
            let running = missions.filter { $0.status == "running" }
            let finished = missions.filter { $0.status != "running" }
            if !running.isEmpty {
                Section("En cours") {
                    ForEach(running) { row($0) }
                }
            }
            if !finished.isEmpty {
                Section("Terminées") {
                    ForEach(finished) { row($0) }
                }
            }
        }
        .refreshable { await refresh() }
    }

    private func row(_ mission: MissionInfo) -> some View {
        Button {
            if store.openConversation(forMission: mission) { dismiss() }
        } label: {
            MissionCard(mission: mission, modelLabel: store.label(forModel: mission.model))
        }
        .tint(.primary)
        .swipeActions {
            if mission.status == "running" {
                Button("Arrêter", systemImage: "stop.fill", role: .destructive) {
                    Task {
                        await store.cancelMission(id: mission.id)
                        await refresh()
                    }
                }
            }
        }
    }

    private func refresh() async {
        guard !store.emergencyActive else { return }
        do {
            missions = try await store.serverMissions()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

private struct MissionCard: View {
    let mission: MissionInfo
    let modelLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                Text(modelLabel ?? "Modèle par défaut")
                Spacer()
                statusLabel
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(mission.title?.isEmpty == false ? mission.title! : "Mission sans titre")
                .font(.body.weight(.medium))
                .lineLimit(2)

            HStack(spacing: 12) {
                Label(duration, systemImage: mission.status == "running" ? "arrow.triangle.2.circlepath" : "clock")
                if let count = mission.actions?.count, count > 0 {
                    Label("\(count) action\(count > 1 ? "s" : "")", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Text(mission.createdAt, format: .dateTime.day().month().hour().minute())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch mission.status {
        case "running": Text("En cours").foregroundStyle(Color.accentColor)
        case "done": Label("Livrée", systemImage: "checkmark").foregroundStyle(.green)
        case "stopped": Text("Arrêtée")
        case "interrupted": Text("Coupée").foregroundStyle(.orange)
        default: Text("Échec").foregroundStyle(.red)
        }
    }

    private var duration: String {
        let seconds = Int((mission.finishedAt ?? .now).timeIntervalSince(mission.createdAt))
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h \(seconds % 3600 / 60) min"
    }
}
