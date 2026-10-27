import SwiftUI

struct MessageBubble: View {
    @Environment(ChatStore.self) private var store
    let message: ChatMessage
    @State private var selecting = false

    private var isUser: Bool { message.role == .user }
    private var isAssistantChat: Bool { store.conversation.assistantID != nil }
    private var steps: [MissionAction] { message.actions.filter { !$0.isResult } }
    private var results: [MissionAction] { message.actions.filter(\.isResult) }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 6) {
                if !isUser && (!steps.isEmpty || message.status == .streaming) {
                    StepsLine(actions: steps, isRunning: message.status == .streaming)
                }
                if message.content.isEmpty && message.status == .streaming {
                    // Nothing written yet: the line above says what Marcel is doing.
                } else if isUser {
                    if !message.attachments.isEmpty {
                        MessageAttachmentsView(attachments: message.attachments)
                    }
                    if !message.content.isEmpty {
                        Text(message.content)
                    }
                    if let via = message.via {
                        Label("via \(via)", systemImage: "paperplane").font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    // No text selection: it would swallow the long press that opens the menu below.
                    // A new assistant or a change of settings comes as a block at the end. Carried out
                    // by the server, it shows as a result below; otherwise as a card to approve.
                    let parts = AssistantDraft.split(AutoBlocks.strip(message.content))
                    let tuned = AssistantProposal.split(parts.text)
                    MarkdownView(text: tuned.text)
                    if message.status == .complete {
                        if let draft = parts.draft, !message.autoApplied("assistant") {
                            NewAssistantCard(message: message, draft: draft)
                        }
                        if let proposal = tuned.proposal, proposal.assistant != nil || isAssistantChat,
                           !message.autoApplied("reglage") {
                            ProposalCard(message: message, proposal: proposal)
                        }
                        if let request = CodeRequestDraft.find(in: message.content) {
                            CodeRequestCard(message: message, draft: request)
                        }
                        if let handOver = HandOverProposal.find(in: message.content) {
                            HandOverCard(message: message, proposal: handOver)
                        }
                        if isAssistantChat, let handoff = MarcelHandoff.find(in: message.content) {
                            HandoffCard(message: message, handoff: handoff)
                        }
                    }
                }
                if !isUser {
                    ForEach(results) { ResultRow(action: $0, message: message) }
                }
                statusLine
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isUser ? Theme.userBubble : Theme.assistantBubble, in: .rect(cornerRadius: 20))
            .contextMenu {
                Button("Copier", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = isUser ? message.content : SelectableTextSheet.plain(message.content)
                }
                if !message.content.isEmpty && message.status != .streaming {
                    Button("Sélectionner le texte", systemImage: "selection.pin.in.out") { selecting = true }
                }
                if !isUser && message.status != .streaming && !message.content.isEmpty {
                    let reading = store.speaker.speakingID == message.id
                    Button(reading ? "Arrêter la lecture" : "Lire à voix haute",
                           systemImage: reading ? "speaker.slash" : "speaker.wave.2") {
                        store.speaker.toggle(message)
                    }
                }
                ShareLink(item: message.content)
                if isUser && !store.isStreaming {
                    Button("Modifier et renvoyer", systemImage: "pencil") { store.edit(message.id) }
                }
                if !isUser && message.id == store.conversation.messages.last?.id && store.canRegenerate {
                    Button("Régénérer", systemImage: "arrow.clockwise") { store.regenerate() }
                }
            }
            if !isUser { Spacer(minLength: 40) }
        }
        .sheet(isPresented: $selecting) {
            SelectableTextSheet(text: message.content)
        }
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isUser ? "Toi" : "Marcel") : \(message.content)")
    }

    @ViewBuilder
    private var statusLine: some View {
        switch message.status {
        case .stopped:
            Label("Arrêté", systemImage: "stop.circle").font(.caption).foregroundStyle(.secondary)
        case .failed:
            Label("Échec de la réponse", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
        case .complete:
            if let model = store.label(forModel: message.model), store.models.count > 1 {
                Label(model, systemImage: "cpu").font(.caption2).foregroundStyle(.secondary)
            }
        case .streaming:
            EmptyView()
        }
    }
}
