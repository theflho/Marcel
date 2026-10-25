import SwiftUI

/// Everything Marcel does, in one place (like the Activity tab of ChatGPT's dots): what waits for
/// the user, what runs now, what is scheduled, and what was delivered.
struct MissionsView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var missions: [MissionInfo] = []
    @State private var routines: [Routine] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if store.emergencyActive {
                    ContentUnavailableView("Arrêt d'urgence actif", systemImage: "exclamationmark.octagon",
                                           description: Text("Aucune requête n'est envoyée au serveur. Reprends depuis le bandeau ou les réglages."))
                } else if let error, missions.isEmpty {
                    ContentUnavailableView("Activité indisponible", systemImage: "wifi.exclamationmark",
                                           description: Text(error))
                } else if loaded && missions.isEmpty && routines.isEmpty {
                    ContentUnavailableView("Rien pour l'instant", systemImage: "checklist",
                                           description: Text("Ce que Marcel fait, même app fermée, et ce qu'il fera à heure fixe apparaîtront ici."))
                } else {
                    list
                }
            }
            .navigationTitle("Activité")
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
            let waiting = missions.filter { $0.status != "running" && ($0.error ?? "").hasPrefix("Je bloque") || $0.needsCheck }
            let running = missions.filter { $0.status == "running" }
            let waitingIDs = Set(waiting.map(\.id))
            let finished = missions.filter { $0.status != "running" && !waitingIDs.contains($0.id) }
            let scheduled = routines.filter { $0.status == "active" }
            if !waiting.isEmpty || store.unseenIdeas > 0 {
                Section {
                    ForEach(waiting) { row($0) }
                    if store.unseenIdeas > 0 {
                        NavigationLink {
                            IdeasView()
                        } label: {
                            Label("\(store.unseenIdeas) idée\(store.unseenIdeas > 1 ? "s" : "") à regarder", systemImage: "lightbulb")
                        }
                    }
                } header: {
                    Text("À voir")
                } footer: {
                    if !waiting.isEmpty { Text("Bloquée, ou dit « c'est fait » sans preuve : ouvre sa conversation pour voir.") }
                }
            }
            Section("En cours") {
                NavigationLink {
                    RobotView()
                } label: {
                    Label("Voir le robot RMA", systemImage: "display")
                }
                ForEach(running) { row($0) }
            }
            if !scheduled.isEmpty {
                Section("Programmé") {
                    ForEach(scheduled) { routine in
                        NavigationLink {
                            RoutinesView()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(routine.title)
                                    .font(.body.weight(.medium))
                                Label(routine.schedule, systemImage: "alarm")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !finished.isEmpty {
                Section("Terminé") {
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
            if let api = store.settings.api, let routines = try? await api.routines() { self.routines = routines }
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
        case "done" where mission.needsCheck: Label("À vérifier", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
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

extension MissionInfo {
    /// Done, but what the reply claims isn't backed by what ran (the server's "À vérifier").
    var needsCheck: Bool {
        status == "done" && (actions ?? []).contains { $0.id == "verify" && $0.status == "cancelled" }
    }
}
