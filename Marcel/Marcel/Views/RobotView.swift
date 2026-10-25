import SwiftUI

/// Watching the RMA robot work in the portal, like the dots' cloud computer: its browser, live
/// while it reads, with every field masked (no login, no password). "Je prends la main" keeps
/// it away from the portal while the user acts there themself.
struct RobotView: View {
    @Environment(ChatStore.self) private var store
    @State private var screen: RobotScreen?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        List {
            Section {
                if let data = screen?.image.flatMap({ Data(base64Encoded: $0) }), let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(.rect(cornerRadius: 10))
                        .overlay(alignment: .topLeading) { badge }
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                } else {
                    ContentUnavailableView("Pas encore d'image", systemImage: "display",
                                           description: Text(error ?? "Le robot montre son écran pendant qu'il lit le portail. Touche « Relire maintenant » pour le voir faire."))
                }
            } footer: {
                if let screen, screen.at.timeIntervalSince1970 > 0 {
                    Text("\(screen.live ? screen.step : "Dernière image") · \(screen.at.formatted(.relative(presentation: .named)))")
                }
            }

            Section {
                Button("Relire maintenant", systemImage: "arrow.clockwise") {
                    act { try await $0.updateAssistant(id: "planning", changes: [:], actions: ["relire"]) }
                }
                .disabled(busy || screen?.hands == true || screen?.live == true)
                if screen?.hands == true {
                    Button("Je rends la main", systemImage: "hand.raised.slash") {
                        act { try await $0.holdRobot(false) }
                    }
                } else {
                    Button("Je prends la main", systemImage: "hand.raised") {
                        act { try await $0.holdRobot(true) }
                    }
                }
            } footer: {
                Text(screen?.hands == true
                     ? "Le robot ne touche plus au portail. Fais ce que tu veux dans l'app RMA, puis rends-lui la main : il relira tout."
                     : "Prendre la main arrête le robot : plus de lecture ni de réponse aux offres tant que tu ne la rends pas.")
            }
        }
        .navigationTitle("Le robot RMA")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Live while open: faster when the robot is working.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(screen?.live == true ? 2 : 8))
            }
        }
    }

    private var badge: some View {
        Text(screen?.live == true ? "EN DIRECT" : "PAUSE")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(screen?.live == true ? Color.red : Color.secondary, in: .capsule)
            .foregroundStyle(.white)
            .padding(8)
    }

    private func refresh() async {
        guard !store.emergencyActive, let api = store.settings.api else { return }
        do {
            screen = try await api.robotScreen()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func act(_ work: @escaping (MarcelAPI) async throws -> some Any) {
        guard let api = store.settings.api else { return }
        busy = true
        Task {
            do { _ = try await work(api) } catch { self.error = error.localizedDescription }
            await refresh()
            busy = false
        }
    }
}
