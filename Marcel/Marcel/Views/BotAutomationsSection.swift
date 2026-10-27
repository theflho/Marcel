import SwiftUI

/// The RMA automations in a bot's card: which bot carries each one, and the explicit hand-over.
/// One of the user's bots (a « Cockpit RMA ») can take the portal reading, the pointage reminders and
/// the offer notifications; the system bot then stops doing them (no second reading, no double
/// notification), and gets them back with one touch.
struct BotAutomationsSection: View {
    @Environment(ChatStore.self) private var store
    let assistant: Assistant
    @State private var asking: Assistant.Automation?

    var body: some View {
        if let automations = assistant.automations, !automations.isEmpty {
            Section {
                ForEach(automations) { automation in
                    row(automation)
                }
            } header: {
                Text("Automatismes RMA")
            } footer: {
                Text(assistant.isCustom
                     ? "Un automatisme confié ici est fait par ce bot seul, avec les mêmes réglages : son bot d'origine arrête. Tu peux le rendre quand tu veux."
                     : "Un seul bot fait chaque automatisme. Confié à l'un de tes bots, il s'arrête ici ; « Reprendre » le ramène.")
            }
            .confirmationDialog(asking.map(title) ?? "", isPresented: Binding(
                get: { asking != nil }, set: { if !$0 { asking = nil } }), titleVisibility: .visible, presenting: asking) { automation in
                Button(buttonLabel(automation)) {
                    Task { await store.handOver(automation.key, to: target(automation)) }
                }
                Button("Annuler", role: .cancel) {}
            } message: { automation in
                Text(message(automation))
            }
        }
    }

    private func row(_ automation: Assistant.Automation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(automation.key))
                .frame(width: 28)
                .foregroundStyle(automation.carried ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(automation.label)
                Text(automation.carried ? "Fait par ce bot" : "Fait par \(automation.ownerName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if automation.carried && !assistant.isCustom {
                Image(systemName: "checkmark").foregroundStyle(.secondary)
            } else {
                Button(buttonLabel(automation)) { asking = automation }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.emergencyActive)
            }
        }
    }

    /// Where the touch sends it: here, or back to its system bot.
    private func target(_ automation: Assistant.Automation) -> String {
        assistant.isCustom && automation.carried ? automation.origin : assistant.id
    }

    private func buttonLabel(_ automation: Assistant.Automation) -> String {
        if !assistant.isCustom { return "Reprendre" }
        return automation.carried ? "Rendre" : "Confier ici"
    }

    private func title(_ automation: Assistant.Automation) -> String {
        if assistant.isCustom && !automation.carried { return "Confier « \(automation.label) » à \(assistant.name) ?" }
        return "Rendre « \(automation.label) » à \(automation.originName) ?"
    }

    private func message(_ automation: Assistant.Automation) -> String {
        if assistant.isCustom && !automation.carried {
            return "\(automation.ownerName) arrête de le faire et \(assistant.name) le fait à sa place, avec les mêmes réglages. Le portail RMA reste en lecture seule."
        }
        let from = assistant.isCustom ? assistant.name : automation.ownerName
        return "\(from) arrête de le faire et \(automation.originName) le reprend, avec les réglages du moment."
    }

    private func icon(_ key: String) -> String {
        switch key {
        case "lecture": "doc.text.magnifyingglass"
        case "pointage": "clock.badge.checkmark"
        default: "bell.badge"
        }
    }
}
