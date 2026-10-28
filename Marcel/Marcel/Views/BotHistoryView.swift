import SwiftUI

/// A bot's earlier conversations, like a chat's archive: « Repartir de zéro » puts the conversation
/// here instead of deleting it. Touch one to read it again; swipe to delete it for good.
struct BotHistoryList: View {
    @Environment(ChatStore.self) private var store
    let assistantID: String?
    /// Opens a conversation, then the screen showing the list closes.
    let onOpen: (UUID) -> Void

    var body: some View {
        let past = store.history(ofBot: assistantID)
        if past.isEmpty {
            Text("Rien pour l'instant. Quand tu repars de zéro, l'ancienne conversation arrive ici.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        ForEach(past) { conversation in
            Button {
                onOpen(conversation.id)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.title)
                        .font(.body.weight(conversation.id == store.currentID ? .semibold : .regular))
                        .lineLimit(1)
                    Text("\(conversation.updatedAt.formatted(.relative(presentation: .named))) · \(conversation.messages.count) message(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .tint(.primary)
            .swipeActions {
                Button("Supprimer", systemImage: "trash", role: .destructive) { store.delete(conversation.id) }
            }
        }
    }
}

/// The history in the bot's card.
struct BotHistorySection: View {
    let assistantID: String?
    let onOpen: (UUID) -> Void

    var body: some View {
        Section {
            BotHistoryList(assistantID: assistantID, onOpen: onOpen)
        } header: {
            Text("Anciennes conversations")
        }
    }
}

/// The history opened from the chat's header.
struct BotHistorySheet: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let assistantID: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        store.openBot(assistantID)
                        dismiss()
                    } label: {
                        Label("Conversation actuelle", systemImage: "bubble.left.and.bubble.right.fill")
                    }
                } footer: {
                    Text("C'est celle qui continue. Les anciennes ci-dessous sont gardées telles quelles, tu peux les relire.")
                }
                BotHistorySection(assistantID: assistantID) { id in
                    store.select(id)
                    dismiss()
                }
            }
            .navigationTitle("Historique · \(store.assistants.first { $0.id == assistantID }?.name ?? "Hermes")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
    }
}

/// Shown over the chat while reading an earlier conversation: it is not the one that continues.
struct PastConversationBanner: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Ancienne conversation")
                    .font(.footnote.weight(.semibold))
                Text(store.conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Revenir à l'actuelle") {
                withAnimation(.snappy) { store.openBot(store.conversation.assistantID) }
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .clipShape(.capsule)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glass(in: .rect(cornerRadius: 16))
        .padding(.horizontal)
        .padding(.bottom, 6)
    }
}
