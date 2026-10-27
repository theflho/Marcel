import SwiftUI

// What a bot does without being asked, like a Grok Bot: its standing task, the tasks the user
// taught it, and the skills shared between bots. The model still has no tool: the server runs
// the task and carries out only that bot's actions, under the "ask first" rules.

/// Its standing task in its card: what, when, its last work and its next wake-up.
struct BotTaskSection: View {
    @Environment(ChatStore.self) private var store
    let assistant: Assistant
    @State private var editing = false
    @State private var running = false

    var body: some View {
        Section {
            if let task = assistant.task {
                Text(task.prompt).font(.subheadline)
                LabeledContent("Prochain réveil", value: task.status == "paused" ? "En pause" : task.next)
                if let last = task.lastRun {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Dernier travail")
                            Spacer()
                            Text(last.at, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                        }
                        Text(last.status == "failed" ? "Échec : \(last.error)"
                             : last.status == "running" ? "En cours…" : last.summary)
                            .font(.caption)
                            .foregroundStyle(last.status == "failed" ? .red : .secondary)
                            .lineLimit(3)
                    }
                } else {
                    Text("Pas encore lancée.").font(.footnote).foregroundStyle(.secondary)
                }
                Button("Modifier la tâche", systemImage: "pencil") { editing = true }
                Button {
                    running = true
                    Task {
                        await store.runTask(of: assistant)
                        running = false
                    }
                } label: {
                    Label(running ? "Lancement…" : "Lancer maintenant", systemImage: "play")
                }
                .disabled(running)
                Button("Retirer la tâche", systemImage: "xmark.circle", role: .destructive) {
                    Task { await store.deleteTask(of: assistant) }
                }
            } else {
                Button("Donner une tâche à \(assistant.name)", systemImage: "plus") { editing = true }
            }
        } header: {
            Text("Tâche permanente")
        } footer: {
            Text("Il la fait seul, l'app fermée, et revient ici avec le résultat. Il peut changer ses propres réglages selon tes Règles ; tout le reste, il le prépare et c'est toi qui le fais.")
        }
        .sheet(isPresented: $editing) {
            BotTaskEditor(assistant: assistant)
        }
    }
}

private struct BotTaskEditor: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let assistant: Assistant
    @State private var prompt = ""
    @State private var when = When.hour
    @State private var sender = ""
    @State private var days: Set<Int> = []
    @State private var time = Calendar.current.date(from: DateComponents(hour: 7, minute: 30)) ?? .now
    @State private var paused = false
    @State private var saving = false

    /// What wakes it up: the hour, or an event the server watches.
    private enum When: String, CaseIterable {
        case hour = "", offer = "offre", planning = "planning", mail = "email", sender = "email:"

        var label: String {
            switch self {
            case .hour: "À une heure fixe"
            case .offer: "À chaque nouvelle offre RMA"
            case .planning: "Quand le planning RMA change"
            case .mail: "À chaque nouvel e-mail"
            case .sender: "À chaque e-mail d'un expéditeur"
            }
        }
    }

    private static let dayLetters = ["L", "M", "M", "J", "V", "S", "D"]
    private static let dayNames = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"]

    private var trigger: String {
        when == .sender ? When.sender.rawValue + sender.trimmingCharacters(in: .whitespaces) : when.rawValue
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Ex. Surveille les offres et prépare ma réponse", text: $prompt, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Ce qu'il fait")
                } footer: {
                    Text("Avec ce qu'il lit ici (sa fiche › « Ce que Marcel lit ici »), ses consignes, ses skills et les tâches que tu lui as apprises.")
                }
                Section("Quand") {
                    Picker("Déclencheur", selection: $when) {
                        ForEach(When.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if when == .sender {
                        TextField("Adresse ou nom de domaine, ex. rma.fr", text: $sender)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                    }
                    if when == .hour {
                        HStack(spacing: 6) {
                            ForEach(0..<7, id: \.self) { day in
                                let on = days.contains(day)
                                Button {
                                    if on { days.remove(day) } else { days.insert(day) }
                                } label: {
                                    Text(Self.dayLetters[day])
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity, minHeight: 34)
                                        .background(on ? Color.accentColor : Color(.tertiarySystemFill), in: .circle)
                                        .foregroundStyle(on ? Color.white : Color.primary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Self.dayNames[day])
                                .accessibilityAddTraits(on ? .isSelected : [])
                            }
                        }
                        DatePicker("Heure", selection: $time, displayedComponents: .hourAndMinute)
                    }
                    Toggle("En pause", isOn: $paused)
                }
            }
            .navigationTitle(assistant.task == nil ? "Nouvelle tâche" : "Modifier la tâche")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        saving = true
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
                        let change = BotTaskChange(
                            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines), trigger: trigger,
                            days: days.sorted().map(String.init).joined(separator: ","),
                            at: String(format: "%02d:%02d", parts.hour ?? 7, parts.minute ?? 30),
                            status: paused ? "paused" : "active", conversationID: assistant.task?.conversationID ?? "")
                        Task {
                            if await store.setTask(change, of: assistant) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespaces).count < 3 || saving
                              || (when == .sender && sender.trimmingCharacters(in: .whitespaces).count < 2))
                }
            }
            .onAppear {
                guard let task = assistant.task else { return }
                prompt = task.prompt
                days = Set(task.days.split(separator: ",").compactMap { Int($0) })
                paused = task.status == "paused"
                if task.trigger.hasPrefix(When.sender.rawValue) {
                    when = .sender
                    sender = String(task.trigger.dropFirst(When.sender.rawValue.count))
                } else {
                    when = When(rawValue: task.trigger) ?? .hour
                }
                let parts = task.at.split(separator: ":").compactMap { Int($0) }
                if parts.count == 2, let date = Calendar.current.date(from: DateComponents(hour: parts[0], minute: parts[1])) {
                    time = date
                }
            }
        }
        .presentationDetents([.large])
    }
}

/// The tasks the user taught it, shown so nothing is learnt behind their back: edit or erase.
struct RecipesSection: View {
    @Environment(ChatStore.self) private var store
    let assistant: Assistant
    @State private var editing: Assistant.Recipe?

    var body: some View {
        Section {
            let recipes = assistant.recipes ?? []
            if recipes.isEmpty {
                Text("Aucune : dis-lui « apprends à… » et décris la tâche étape par étape.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(recipes) { recipe in
                Button {
                    editing = recipe
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recipe.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                        Text("\(recipe.steps.count) étape(s) · \(recipe.steps.joined(separator: " → "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .swipeActions {
                    Button("Effacer", systemImage: "trash", role: .destructive) {
                        Task { await store.deleteRecipe(recipe, of: assistant) }
                    }
                }
            }
        } header: {
            Text("Tâches apprises")
        } footer: {
            Text("Demande-lui de refaire l'une d'elles, ou mets-la dans sa tâche permanente.")
        }
        .sheet(item: $editing) { recipe in
            RecipeEditor(assistant: assistant, recipe: recipe)
        }
    }
}

private struct RecipeEditor: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let assistant: Assistant
    let recipe: Assistant.Recipe
    @State private var title = ""
    @State private var steps = ""
    @State private var saving = false

    private var lines: [String] {
        steps.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Titre") {
                    TextField("Titre", text: $title)
                }
                Section {
                    TextField("Une étape par ligne", text: $steps, axis: .vertical)
                        .lineLimit(4...14)
                } header: {
                    Text("Étapes")
                } footer: {
                    Text("Une étape par ligne, 12 au plus.")
                }
            }
            .navigationTitle("Tâche apprise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        saving = true
                        Task {
                            if await store.updateRecipe(recipe, title: title, steps: lines, of: assistant) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).count < 3 || lines.isEmpty || lines.count > 12
                              || saving)
                }
            }
            .onAppear {
                title = recipe.title
                steps = recipe.steps.joined(separator: "\n")
            }
        }
    }
}

/// The shared skills, ticked for this bot; written once in "Skills des bots".
struct BotSkillsSection: View {
    @Environment(ChatStore.self) private var store
    let assistant: Assistant

    var body: some View {
        Section {
            ForEach(assistant.skills ?? []) { skill in
                Toggle(skill.title, isOn: Binding(
                    get: { skill.on },
                    set: { on in Task { await store.setSkill(skill.id, on, of: assistant) } }))
            }
            NavigationLink("Skills des bots") {
                BotSkillsView()
            }
        } header: {
            Text("Skills")
        } footer: {
            Text("Des consignes que tu écris une fois et donnes à plusieurs bots. Ce n'est que du texte : aucune skill ne donne d'outil.")
        }
    }
}

/// Every skill shared between bots: written, changed or erased here.
struct BotSkillsView: View {
    @Environment(ChatStore.self) private var store
    @State private var skills: [BotSkill] = []
    @State private var editing: BotSkill?
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        List {
            if skills.isEmpty {
                Text("Aucune skill pour l'instant. Ex. « Ton pour répondre à RMA », « Format d'un brief ».")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(skills) { skill in
                Button {
                    editing = skill
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                        Text(skill.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if !skill.bots.isEmpty {
                            Text(skill.bots.compactMap { id in store.assistants.first { $0.id == id }?.name }
                                .joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .swipeActions {
                    Button("Effacer", systemImage: "trash", role: .destructive) {
                        Task { await delete(skill) }
                    }
                }
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .navigationTitle("Skills des bots")
        .toolbar {
            Button("Nouvelle skill", systemImage: "plus") { adding = true }
        }
        .sheet(isPresented: $adding) {
            SkillEditor(skill: nil) { title, text in await save(nil, title, text) }
        }
        .sheet(item: $editing) { skill in
            SkillEditor(skill: skill) { title, text in await save(skill, title, text) }
        }
        .task { await load() }
        .disabled(store.emergencyActive)
    }

    private func load() async {
        guard let api = store.settings.api else { return }
        do {
            skills = try await api.botSkills()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save(_ skill: BotSkill?, _ title: String, _ text: String) async -> Bool {
        guard let api = store.settings.api else { return false }
        do {
            if let skill {
                _ = try await api.updateBotSkill(id: skill.id, title: title, text: text)
            } else {
                _ = try await api.addBotSkill(title: title, text: text)
            }
            await load()
            await store.refreshAssistants()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func delete(_ skill: BotSkill) async {
        guard let api = store.settings.api else { return }
        do {
            try await api.deleteBotSkill(id: skill.id)
            await load()
            await store.refreshAssistants()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct SkillEditor: View {
    @Environment(\.dismiss) private var dismiss
    let skill: BotSkill?
    let onSave: (String, String) async -> Bool
    @State private var title = ""
    @State private var text = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Nom") {
                    TextField("Ex. Ton pour répondre à RMA", text: $title)
                }
                Section {
                    TextField("Ce que le bot doit suivre", text: $text, axis: .vertical)
                        .lineLimit(4...14)
                } header: {
                    Text("Consigne")
                } footer: {
                    Text("800 caractères au plus.")
                }
            }
            .navigationTitle(skill == nil ? "Nouvelle skill" : "Modifier la skill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        saving = true
                        Task {
                            if await onSave(title.trimmingCharacters(in: .whitespacesAndNewlines),
                                            text.trimmingCharacters(in: .whitespacesAndNewlines)) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).count < 2
                              || text.trimmingCharacters(in: .whitespaces).count < 3 || text.count > 800 || saving)
                }
            }
            .onAppear {
                title = skill?.title ?? ""
                text = skill?.text ?? ""
            }
        }
    }
}
