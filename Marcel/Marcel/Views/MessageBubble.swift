import SwiftUI

struct MessageBubble: View {
    @Environment(ChatStore.self) private var store
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 6) {
                if !isUser && !message.actions.isEmpty {
                    ActionsCard(actions: message.actions, isRunning: message.status == .streaming)
                }
                if message.content.isEmpty && message.status == .streaming {
                    TypingIndicator()
                } else if isUser {
                    if !message.attachments.isEmpty {
                        MessageAttachmentsView(attachments: message.attachments)
                    }
                    if !message.content.isEmpty {
                        Text(message.content)
                    }
                } else {
                    // No text selection: it would swallow the long press that opens the menu below.
                    MarkdownView(text: message.content)
                }
                statusLine
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isUser ? Theme.userBubble : Theme.assistantBubble, in: .rect(cornerRadius: 20))
            .contextMenu {
                Button("Copier", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.content }
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

private struct TypingIndicator: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: 7, height: 7)
                    .opacity(phase == index ? 1 : 0.35)
            }
        }
        .padding(.vertical, 6)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                withAnimation(.easeInOut(duration: 0.2)) { phase = (phase + 1) % 3 }
            }
        }
        .accessibilityLabel("Marcel écrit")
    }
}
