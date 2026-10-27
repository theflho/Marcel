import SwiftUI

// "/" at the start of the composer: a short menu of commands, like Grok or Telegram bots.
// A mode ("/planning") or "/nouveau" is handled here; a skill ("/code …") is sent as typed and
// the server tells Hermes which skill to follow.

struct SlashCommand: Identifiable, Hashable {
    enum Kind: Hashable {
        /// Open Marcel (nil) or an assistant, like a bot in Grok Bot.
        case mode(String?)
        /// Put "/name " in the composer, for the request to follow.
        case skill
        case newConversation
        case privateConversation
    }

    let name: String
    let detail: String
    let icon: String
    let kind: Kind

    var id: String { name }
}

extension Assistant {
    /// "planning", "recettes"…: how "/" calls it.
    var slashName: String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "fr"))
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

extension ChatStore {
    var slashCommands: [SlashCommand] {
        var commands = [SlashCommand(name: "nouveau", detail: "Nouvelle conversation", icon: "square.and.pencil",
                                     kind: .newConversation),
                        SlashCommand(name: "prive", detail: "Conversation privée, rien n'est gardé", icon: "lock",
                                     kind: .privateConversation),
                        SlashCommand(name: "marcel", detail: "Ouvrir Marcel", icon: "sparkles", kind: .mode(nil))]
        commands += assistants.map {
            SlashCommand(name: $0.slashName, detail: "Ouvrir \($0.name)", icon: "person.crop.circle", kind: .mode($0.id))
        }
        commands += [
            SlashCommand(name: "code", detail: "Modifier l'app ou son serveur", icon: "chevron.left.forwardslash.chevron.right", kind: .skill),
            SlashCommand(name: "donnees", detail: "Chercher dans ce que Marcel sait", icon: "tray.full", kind: .skill),
            SlashCommand(name: "routine", detail: "Une tâche à heure fixe", icon: "clock", kind: .skill),
            SlashCommand(name: "objectif", detail: "Un objectif à suivre", icon: "target", kind: .skill),
            SlashCommand(name: "web", detail: "Chercher sur le web", icon: "globe", kind: .skill),
        ]
        return commands
    }

    /// The commands matching what follows "/", while the first word is being typed.
    var slashSuggestions: [SlashCommand] {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return [] }
        let typed = draft.dropFirst().lowercased()
        return slashCommands.filter { $0.name.hasPrefix(typed) }
    }

    func pick(_ command: SlashCommand) {
        switch command.kind {
        case .newConversation:
            draft = ""
            newConversation()
        case .privateConversation:
            draft = ""
            newPrivateConversation()
        case .mode(let id):
            draft = ""
            openBot(id)
        case .skill:
            // Skills are Marcel's: an assistant has no tool.
            if conversation.assistantID != nil { newConversation() }
            draft = "/\(command.name) "
        }
    }

    /// "/planning lis demain" sent as is: switch mode and send the rest. False when the message
    /// isn't a mode command (a skill command is sent as typed).
    func applySlashMode() -> Bool {
        guard draft.hasPrefix("/") else { return false }
        let word = draft.dropFirst().prefix { !$0.isWhitespace }.lowercased()
        guard let command = slashCommands.first(where: { $0.name == word }), command.kind != .skill else { return false }
        let rest = draft.dropFirst(word.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
        pick(command)
        draft = rest
        return true
    }
}

/// Above the composer while "/…" is typed.
struct SlashPalette: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        let commands = store.slashSuggestions
        if !commands.isEmpty {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(commands) { command in
                        Button {
                            withAnimation(.snappy) { store.pick(command) }
                        } label: {
                            HStack(spacing: 12) {
                                icon(for: command)
                                    .frame(width: 28)
                                Text("/\(command.name)")
                                    .font(.subheadline.weight(.semibold).monospaced())
                                Text(command.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
            .glass(in: .rect(cornerRadius: 20), interactive: false)
            .padding(.horizontal, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func icon(for command: SlashCommand) -> some View {
        if case .mode(let id?) = command.kind, let assistant = store.assistants.first(where: { $0.id == id }) {
            MarcelAvatar(size: 26, bot: assistant.id, tile: false)
        } else {
            Image(systemName: command.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
