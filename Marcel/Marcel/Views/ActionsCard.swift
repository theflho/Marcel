import SwiftUI

/// The agent's steps for one reply ("8 actions"), collapsed to the last few until expanded.
/// Touching a step opens its full detail, where the text can be selected and copied.
struct ActionsCard: View {
    let actions: [MissionAction]
    let isRunning: Bool
    @State private var expanded = false
    @State private var opened: MissionAction?

    private static let collapsedCount = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(actions.count == 1 ? "1 action" : "\(actions.count) actions")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if isRunning {
                    Label("En cours", systemImage: "circle.dotted")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Label("Terminé", systemImage: "checkmark")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.green.opacity(0.12), in: .capsule)
                }
            }

            let hidden = expanded ? 0 : max(0, actions.count - Self.collapsedCount)
            ForEach(actions.suffix(actions.count - hidden)) { action in
                Button {
                    opened = action
                } label: {
                    ActionRow(action: action)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Affiche le détail")
            }

            if actions.count > Self.collapsedCount {
                HStack {
                    if hidden > 0 {
                        Text(hidden == 1 ? "1 étape plus tôt" : "\(hidden) étapes plus tôt")
                    }
                    Spacer()
                    Button(expanded ? "Réduire" : "Tout voir") {
                        withAnimation(.snappy) { expanded.toggle() }
                    }
                    .font(.caption.weight(.semibold))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Theme.surface.opacity(0.7), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(actions.count) actions, \(isRunning ? "en cours" : "terminé")")
        .sheet(item: $opened) { action in
            ActionDetail(action: actions.first { $0.id == action.id } ?? action)
        }
    }
}

/// One step in full: what it was, how it went, and everything the server said about it.
private struct ActionDetail: View {
    @Environment(\.dismiss) private var dismiss
    let action: MissionAction

    /// The memory card lists its facts after "2 du noyau, 1 des archives : ", separated by " · ".
    private var lines: (intro: String, items: [String]) {
        let detail = action.detail ?? ""
        guard action.id == "memory", let colon = detail.range(of: " : ") else { return (detail, []) }
        let items = detail[colon.upperBound...].components(separatedBy: " · ").filter { !$0.isEmpty }
        return (String(detail[..<colon.lowerBound]), items)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("État", value: statusLabel)
                    if let name = action.name, !name.isEmpty {
                        LabeledContent("Étape", value: name)
                    }
                }
                let lines = lines
                if !lines.items.isEmpty {
                    Section(lines.intro) {
                        ForEach(Array(lines.items.enumerated()), id: \.offset) { _, item in
                            Text(item).textSelection(.enabled)
                        }
                    }
                } else if !lines.intro.isEmpty {
                    Section("Détail") {
                        Text(lines.intro)
                            .font(isMarcelCard ? .callout : .callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(action.name?.isEmpty == false ? action.name! : "Action")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
                if let detail = action.detail, !detail.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Copier", systemImage: "doc.on.doc") { UIPasteboard.general.string = detail }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Cards Marcel writes himself (memory, e-mails, model…) are sentences; the agent's tool
    /// calls are arguments, shown like code.
    private var isMarcelCard: Bool {
        ["memory", "mail", "shield", "routine", "model", "files"].contains(action.id) || action.id.hasPrefix("auto-")
    }

    private var statusLabel: String {
        switch action.status {
        case "running": "En cours"
        case "cancelled": "Annulée ou refusée"
        default: "Terminée"
        }
    }
}

private struct ActionRow: View {
    let action: MissionAction

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            statusIcon
            VStack(alignment: .leading, spacing: 1) {
                if let detail = action.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let name = action.name, !name.isEmpty {
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch action.status {
        case "running":
            ProgressView().controlSize(.mini)
        case "cancelled":
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.caption)
        default:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        }
    }
}

/// The agent's steps folded to one line, like Grok's: what Marcel is doing now while he works
/// ("Lecture du planning…"), then "8 étapes". Touching it unfolds the full card.
struct StepsLine: View {
    let actions: [MissionAction]
    let isRunning: Bool
    @State private var expanded = false

    private var activity: String { Self.activity(of: actions) }

    /// What the step in progress does, in words (also under the name in the header).
    static func activity(of actions: [MissionAction]) -> String {
        guard let step = actions.last(where: { $0.status == "running" }) else {
            return actions.isEmpty ? "Réflexion…" : "Rédaction de la réponse…"
        }
        let name = (step.name ?? "").lowercased()
        let phrases: [(String, String)] = [
            ("marcel_planning", "Lecture du planning…"), ("marcel_offres", "Lecture des offres…"),
            ("marcel_robot", "Lecture du robot RMA…"), ("marcel_code", "Travail sur son code…"),
            ("marcel_journaux", "Lecture des journaux du serveur…"), ("marcel_", "Consultation de tes données…"),
            ("search", "Recherche sur le web…"), ("recherche", "Recherche…"), ("extract", "Lecture d'une page…"),
            ("browser", "Navigation sur un site…"), ("terminal", "Commande sur le serveur…"),
            ("bash", "Commande sur le serveur…"), ("read", "Lecture d'un fichier…"), ("lecture", "Lecture…"),
            ("write", "Écriture d'un fichier…"), ("patch", "Modification d'un fichier…"), ("écriture", "Écriture…"),
            ("memory", "Mémoire…"), ("skill", "Lecture d'une skill…"),
        ]
        if let phrase = phrases.first(where: { name.contains($0.0) })?.1 { return phrase }
        return step.name.map { "\($0)…" } ?? "Réflexion…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if isRunning {
                        ProgressView().controlSize(.mini)
                        Text(activity)
                    } else {
                        Image(systemName: "checkmark.circle")
                        Text(actions.count == 1 ? "1 étape" : "\(actions.count) étapes")
                    }
                    if !actions.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(actions.isEmpty)
            .accessibilityLabel(isRunning ? activity : "\(actions.count) étapes")
            .accessibilityHint(expanded ? "Masque les étapes" : "Affiche les étapes")
            if expanded {
                ActionsCard(actions: actions, isRunning: isRunning)
                    .transition(.opacity)
            }
        }
    }
}

/// What Marcel did himself at the end of his reply ("✓ 3 missions ajoutées"), with "Annuler"
/// when it can be taken back. What waits for the user gets Grok Bot's three answers: once, always
/// (this kind of action goes to "Tout seul" in Règles), or refuse.
struct ResultRow: View {
    @Environment(ChatStore.self) private var store
    let action: MissionAction
    let message: ChatMessage
    @State private var confirming = false
    @State private var undoing = false

    private var undone: Bool { message.undone.contains(action.id) }
    private var declined: Bool { message.declined.contains(action.id) }
    private var waiting: Bool { action.awaitsApproval && !declined }
    private var done: Bool { action.status == "done" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: undone ? "arrow.uturn.backward.circle" : done ? "checkmark.circle.fill"
                      : declined ? "hand.raised.slash" : waiting ? "hand.raised.circle" : "xmark.circle")
                    .foregroundStyle(undone || declined ? Color.secondary : done ? Color.green
                                     : waiting ? Color.accentColor : Color.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.detail?.isEmpty == false ? action.detail! : (action.name ?? "Fait"))
                        .font(.footnote.weight(.medium))
                        .strikethrough(undone || declined)
                        .foregroundStyle(undone || declined ? .secondary : .primary)
                    if undone {
                        Text("Annulé").font(.caption2).foregroundStyle(.secondary)
                    } else if declined {
                        Text("Refusé").font(.caption2).foregroundStyle(.secondary)
                    } else if let name = action.name {
                        Text(name).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if done, !undone, action.undo != nil {
                    Button {
                        confirming = true
                    } label: {
                        if undoing { ProgressView().controlSize(.mini) } else { Text("Annuler") }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(undoing || store.emergencyActive)
                }
            }
            if waiting {
                HStack(spacing: 6) {
                    Button {
                        answer { await store.approve(action, in: message.id) }
                    } label: {
                        if undoing { ProgressView().controlSize(.mini) } else { Text("Autoriser une fois") }
                    }
                    .buttonStyle(.borderedProminent)
                    if action.ruleKind != nil {
                        Button("Toujours") {
                            answer { await store.approveAlways(action, in: message.id) }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Toujours autoriser")
                    }
                    Button("Refuser", role: .destructive) {
                        store.decline(action, in: message.id)
                    }
                    .buttonStyle(.bordered)
                }
                .font(.caption.weight(.semibold))
                .controlSize(.small)
                .disabled(undoing || store.emergencyActive)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.surface.opacity(0.7), in: .rect(cornerRadius: 12))
        .confirmationDialog("Annuler ce que Marcel a fait ?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Oui, annuler", role: .destructive) {
                undoing = true
                Task {
                    await store.undo(action, in: message.id)
                    undoing = false
                }
            }
            Button("Non", role: .cancel) {}
        } message: {
            Text(action.detail ?? "")
        }
    }

    private func answer(_ work: @escaping () async -> Void) {
        undoing = true
        Task {
            await work()
            undoing = false
        }
    }
}
