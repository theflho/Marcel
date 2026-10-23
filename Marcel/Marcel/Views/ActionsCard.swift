import SwiftUI

/// The agent's steps for one reply ("8 actions"), collapsed to the last few until expanded.
struct ActionsCard: View {
    let actions: [MissionAction]
    let isRunning: Bool
    @State private var expanded = false

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
                ActionRow(action: action)
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
