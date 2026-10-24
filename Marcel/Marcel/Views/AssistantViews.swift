import SwiftUI

/// Top of an assistant's conversation: what it does, its settings and the instructions it keeps.
struct AssistantCard: View {
    @Environment(ChatStore.self) private var store
    let assistant: Assistant
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Text(assistant.emoji).font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(assistant.summary)
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.leading)
                        Text(assistant.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(.rect)
            }
            .tint(.primary)
            .accessibilityHint(expanded ? "Masque les réglages" : "Affiche les réglages")

            if expanded {
                Divider()
                ForEach(assistant.settings) { setting in
                    HStack(alignment: .firstTextBaseline) {
                        Text(setting.label).font(.footnote)
                        Spacer()
                        Text(setting.shown(setting.value))
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                if !assistant.instructions.isEmpty {
                    Divider()
                    Text("Consignes retenues").font(.footnote.weight(.semibold))
                    ForEach(assistant.instructions) { instruction in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•").font(.footnote)
                            Text(instruction.text).font(.footnote)
                            Spacer(minLength: 0)
                            Button("Retirer", systemImage: "xmark.circle.fill") {
                                Task { await store.deleteInstruction(instruction, of: assistant) }
                            }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Pour changer un réglage, écris-le simplement : je te propose le changement, il ne s'applique que si tu appuies sur « Appliquer ».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Theme.surface, in: .rect(cornerRadius: 18))
        .padding(.horizontal)
    }
}

/// A change an assistant proposed, under its reply: nothing happens until "Appliquer".
struct ProposalCard: View {
    @Environment(ChatStore.self) private var store
    let message: ChatMessage
    let proposal: AssistantProposal
    @State private var applying = false

    private var assistant: Assistant? {
        store.conversations.first { $0.messages.contains { $0.id == message.id } }.flatMap(store.assistant(for:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(proposal.resume.isEmpty ? "Changement proposé" : proposal.resume, systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
            ForEach(proposal.changes.keys.sorted(), id: \.self) { key in
                let setting = assistant?.setting(key)
                let value = proposal.changes[key]!
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(setting?.label ?? key)
                    Spacer()
                    if let setting {
                        Text(setting.shown(setting.value)).foregroundStyle(.secondary).strikethrough()
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(setting?.shown(value) ?? "\(value)").fontWeight(.medium)
                }
                .font(.footnote)
            }
            let consigne = proposal.consigne.trimmingCharacters(in: .whitespacesAndNewlines)
            if !consigne.isEmpty {
                Text("Consigne à retenir : « \(consigne) »").font(.footnote)
            }
            switch message.proposalDecision {
            case "applied"?:
                Label("Appliqué", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green)
            case "cancelled"?:
                Label("Annulé", systemImage: "xmark.circle").font(.footnote).foregroundStyle(.secondary)
            default:
                HStack {
                    Button {
                        applying = true
                        Task {
                            await store.applyProposal(message.id)
                            applying = false
                        }
                    } label: {
                        if applying { ProgressView().controlSize(.small) } else { Text("Appliquer") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(applying || store.emergencyActive)
                    Button("Annuler") { store.cancelProposal(message.id) }
                        .buttonStyle(.bordered)
                        .disabled(applying)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Theme.background, in: .rect(cornerRadius: 14))
    }
}
