import SwiftUI

/// Hermes' live approval, bound to the exact mission and native run by the backend.
struct HermesApprovalCard: View {
    @Environment(ChatStore.self) private var store
    let action: MissionAction
    let message: ChatMessage
    @State private var sending = false
    @State private var resolved = false
    @State private var error: String?

    var body: some View {
        if !resolved {
            VStack(alignment: .leading, spacing: 8) {
                Label("Hermes attend ton accord", systemImage: "hand.raised")
                    .font(.subheadline.weight(.semibold))
                Text(action.detail ?? "Valider cette action ?").font(.callout).textSelection(.enabled)
                HStack {
                    Button("Autoriser cette fois") { answer("once") }
                    Button("Refuser", role: .destructive) { answer("deny") }
                }
                .buttonStyle(.bordered)
                .disabled(sending || store.emergencyActive || message.serverID.map { $0 != store.settings.activeID } == true)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .padding(10)
            .background(Theme.surface.opacity(0.7), in: .rect(cornerRadius: 14))
        }
    }

    private func answer(_ choice: String) {
        guard !store.emergencyActive, let api = store.settings.api, let mission = message.missionID else { return }
        sending = true
        Task {
            defer { sending = false }
            do {
                _ = try await api.hermesApproval(mission: mission, action: action.id, choice: choice)
                resolved = true
            } catch { self.error = error.localizedDescription }
        }
    }
}
