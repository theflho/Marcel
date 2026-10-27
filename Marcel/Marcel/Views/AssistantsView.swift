import SwiftUI

/// Marcel's assistants, out of the conversations: what each does, its settings and the
/// instructions it keeps. A conversation picks one as its mode.
struct AssistantsView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Opens the assistant's conversation (the one that continues), then closes the screen.
    var onStart: (Assistant) -> Void = { _ in }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.assistants) { assistant in
                        NavigationLink {
                            AssistantDetailView(assistantID: assistant.id, onStart: start) { id in
                                store.select(id)
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: 12) {
                                MarcelAvatar(size: 40, bot: assistant.id, state: store.face(ofBot: assistant.id))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(assistant.name).font(.body.weight(.semibold))
                                    Text(assistant.status.isEmpty ? assistant.summary : assistant.status)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button("Discuter", systemImage: "bubble.left.and.bubble.right") { start(assistant) }
                                .tint(.accentColor)
                        }
                    }
                } footer: {
                    Text("Ce sont les sujets dont Marcel s'occupe pour toi. Pour en ajouter un, demande-le-lui (« crée-moi un bot pour… »).")
                }
            }
            .overlay {
                if store.assistants.isEmpty {
                    ContentUnavailableView("Aucun assistant", systemImage: "person.2",
                                           description: Text("Ils arrivent quand le serveur répond."))
                }
            }
            .navigationTitle("Bots de Marcel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .task { await store.refreshAssistants() }
        }
    }

    private func start(_ assistant: Assistant) {
        onStart(assistant)
        dismiss()
    }
}

private struct AssistantDetailView: View {
    @Environment(ChatStore.self) private var store
    let assistantID: String
    let onStart: (Assistant) -> Void
    /// Opens one of its conversations, then closes the screen.
    let onOpen: (UUID) -> Void
    @State private var confirmingDelete = false

    var body: some View {
        // Read from the store each time, so a saved setting shows at once.
        if let assistant = store.assistants.first(where: { $0.id == assistantID }) {
            List {
                Section {
                    VStack(spacing: 8) {
                        MarcelAvatar(size: 72, bot: assistant.id, state: store.face(ofBot: assistant.id))
                        Text(assistant.summary)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                        if !assistant.status.isEmpty {
                            Text(assistant.status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    Button {
                        onStart(assistant)
                    } label: {
                        Label("Ouvrir sa conversation", systemImage: "bubble.left.and.bubble.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if assistant.id == "recrutements" {
                    Section("Offres en attente") {
                        OffersList(offers: store.offers)
                    }
                }

                BotPageSection(assistantID: assistant.id)

                BotTaskSection(assistant: assistant)

                BotRunsSection(assistantID: assistant.id, onOpen: onOpen)

                BotHistorySection(assistantID: assistant.id, onOpen: onOpen)

                BotRoutinesSection(assistant: assistant) {
                    // Like Grok Bot's "Add routine": it is asked in the bot's conversation.
                    onStart(assistant)
                    store.draft = "Relance-moi "
                }

                BotNotificationsSection(assistantID: assistant.id)

                BotRulesSection(assistantID: assistant.id)

                if let reads = assistant.reads, !reads.isEmpty {
                    Section {
                        ForEach(reads) { read in
                            Toggle(read.label, isOn: Binding(
                                get: { read.on },
                                set: { on in Task { await store.setRead(read.key, on, of: assistant) } }))
                        }
                    } header: {
                        Text("Ce que Marcel lit ici")
                    } footer: {
                        Text("En lecture seule, dans les conversations de ce bot. Il n'y gagne aucun outil : il ne peut ni écrire, ni envoyer, ni rien supprimer.")
                    }
                }

                if !assistant.settings.isEmpty {
                    Section {
                        ForEach(assistant.settings) { setting in
                            SettingRow(assistant: assistant, setting: setting)
                        }
                    } header: {
                        Text("Réglages")
                    } footer: {
                        Text("Tu peux aussi les changer en le disant dans une conversation avec \(assistant.name).")
                    }
                }

                Section {
                    if assistant.instructions.isEmpty {
                        Text("Aucune pour l'instant : dis-lui ce qu'il doit retenir.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(assistant.instructions) { instruction in
                        Text(instruction.text)
                            .font(.subheadline)
                            .swipeActions {
                                Button("Retirer", systemImage: "trash", role: .destructive) {
                                    Task { await store.deleteInstruction(instruction, of: assistant) }
                                }
                            }
                    }
                } header: {
                    Text("Consignes retenues")
                }

                RecipesSection(assistant: assistant)

                BotSkillsSection(assistant: assistant)

                if assistant.isCustom {
                    Section {
                        Button("Supprimer le bot", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .navigationTitle(assistant.name)
            .navigationBarTitleDisplayMode(.inline)
            .disabled(store.emergencyActive)
            .confirmationDialog("Supprimer \(assistant.name) ?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) { Task { await store.deleteAssistant(assistant) } }
            } message: {
                Text("Ses conversations restent, avec Marcel.")
            }
        } else {
            ContentUnavailableView("Assistant supprimé", systemImage: "person.slash")
        }
    }
}

/// One setting, changed right here: saved by the server as soon as it changes.
private struct SettingRow: View {
    @Environment(ChatStore.self) private var store
    let assistant: Assistant
    let setting: Assistant.Setting
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        switch (setting.kind, setting.value) {
        case ("int", .int(let number)):
            Stepper(value: Binding(get: { number }, set: { save(.int($0)) }), in: setting.min...max(setting.min, setting.max)) {
                LabeledContent(setting.label, value: setting.shown(setting.value))
            }
        case ("bool", .bool(let on)):
            Toggle(setting.label, isOn: Binding(get: { on }, set: { save(.bool($0)) }))
        case ("choice", .text(let current)):
            Picker(setting.label, selection: Binding(get: { current }, set: { save(.text($0)) })) {
                ForEach(setting.choices, id: \.value) { Text($0.label).tag($0.value) }
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                Text(setting.label).font(.footnote).foregroundStyle(.secondary)
                TextField(setting.help.isEmpty ? setting.label : setting.help, text: $text, axis: .vertical)
                    .focused($editing)
                    .submitLabel(.done)
                    .onSubmit(saveText)
                    .onChange(of: editing) { _, focused in if !focused { saveText() } }
            }
            .onAppear { if case .text(let value) = setting.value { text = value } }
        }
    }

    private func save(_ value: SettingValue) {
        Task { await store.updateSetting(setting.key, to: value, of: assistant) }
    }

    private func saveText() {
        guard case .text(let value) = setting.value, text != value else { return }
        save(.text(text))
    }
}
