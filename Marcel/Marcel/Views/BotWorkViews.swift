import SwiftUI
import UserNotifications

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
        case hour = "", offer = "offre", planning = "planning", mail = "email", sender = "email:", box = "boite",
             boxSender = "boite:"

        var label: String {
            switch self {
            case .hour: "À une heure fixe"
            case .offer: "À chaque nouvelle offre RMA"
            case .planning: "Quand le planning RMA change"
            case .mail: "À chaque nouvel e-mail"
            case .sender: "À chaque e-mail d'un expéditeur"
            case .box: "À chaque e-mail reçu par Marcel"
            case .boxSender: "À chaque e-mail reçu par Marcel d'un expéditeur"
            }
        }

        /// Waits for one sender, typed below.
        var takesSender: Bool { self == .sender || self == .boxSender }
    }

    private static let dayLetters = ["L", "M", "M", "J", "V", "S", "D"]
    private static let dayNames = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"]

    private var trigger: String {
        when.takesSender ? when.rawValue + sender.trimmingCharacters(in: .whitespaces) : when.rawValue
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
                    if when.takesSender {
                        TextField(when == .boxSender ? "Adresse ou nom de domaine, ex. ticketmaster"
                                                     : "Adresse ou nom de domaine, ex. rma.fr", text: $sender)
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
                              || (when.takesSender && sender.trimmingCharacters(in: .whitespaces).count < 2))
                }
            }
            .onAppear {
                guard let task = assistant.task else { return }
                prompt = task.prompt
                days = Set(task.days.split(separator: ",").compactMap { Int($0) })
                paused = task.status == "paused"
                if let kind = [When.sender, .boxSender].first(where: { task.trigger.hasPrefix($0.rawValue) }) {
                    when = kind
                    sender = String(task.trigger.dropFirst(kind.rawValue.count))
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

/// Its Notifications switch, like a Grok Bot's profile: "when it has finished or is waiting for you".
/// It needs the iPhone's permission too; without it, a way to Réglages.
struct BotNotificationsSection: View {
    let assistantID: String?
    @State private var on = true
    @State private var allowed = true

    var body: some View {
        Section {
            Toggle("Me prévenir", isOn: Binding(get: { on }, set: { value in
                on = value
                BotPrefs.set(BotPrefs.mutedKey, assistantID, !value)
            }))
            if !allowed {
                Button("Ouvrir Réglages", systemImage: "gear") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text(allowed ? "Quand il a fini ou qu'il attend ton accord."
                 : "Les notifications de Marcel sont coupées sur cet iPhone.")
        }
        .task {
            on = BotPrefs.notifies(assistantID)
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            allowed = settings.authorizationStatus != .denied
        }
    }
}

/// The relances it was asked for, like the routines in a Grok Bot's profile: Active, next run,
/// instruction and run history; swipe to delete. A new one is asked in its conversation.
struct BotRoutinesSection: View {
    @Environment(ChatStore.self) private var store
    let assistant: Assistant
    let onAdd: () -> Void
    @State private var routines: [Routine] = []
    @State private var error: String?

    var body: some View {
        Section {
            if routines.isEmpty {
                Text("Aucune pour l'instant.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(routines) { routine in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(get: { routine.status == "active" }, set: { active in
                        Task { await change(routine) { _ = try await $0.updateRoutine(id: routine.id,
                                                                                   RoutineChange(status: active ? "active" : "paused")) } }
                    })) {
                        Text(routine.title).font(.subheadline.weight(.medium))
                    }
                    Text(routine.prompt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    HStack {
                        Label(routine.next ?? routine.schedule, systemImage: "clock")
                        Spacer()
                        NavigationLink("Historique") { RoutineHistoryView(routine: routine) }
                            .fixedSize()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("Supprimer", systemImage: "trash", role: .destructive) {
                        Task { await change(routine) { try await $0.deleteRoutine(id: routine.id) } }
                    }
                }
            }
            Button("Ajouter une relance", systemImage: "plus", action: onAdd)
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Relances")
        } footer: {
            Text("Une relance se demande dans sa conversation : « relance-moi chaque lundi à 9 h pour… ».")
        }
        .task { await load() }
    }

    private func load() async {
        guard !store.emergencyActive, let api = store.settings.api else { return }
        do {
            routines = try await api.routines().filter { $0.assistant == assistant.id && !$0.isTask }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func change(_ routine: Routine, _ work: (MarcelAPI) async throws -> Void) async {
        guard !store.emergencyActive, let api = store.settings.api else { return }
        do {
            try await work(api)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A routine's last runs: done, running or failed, with the reason.
private struct RoutineHistoryView: View {
    @Environment(ChatStore.self) private var store
    let routine: Routine
    @State private var runs: [RoutineRun] = []

    var body: some View {
        List {
            if runs.isEmpty {
                Text("Pas encore passée.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(runs) { run in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Label(run.status == "done" ? "Réussie" : run.status == "running" ? "En cours" : "Échec",
                              systemImage: run.status == "done" ? "checkmark.circle.fill"
                                : run.status == "running" ? "hourglass" : "exclamationmark.circle")
                            .foregroundStyle(run.status == "failed" ? .red : .primary)
                        Spacer()
                        Text(run.at, format: .dateTime.day().month().hour().minute()).foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    if !run.error.isEmpty {
                        Text(run.error).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(routine.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let api = store.settings.api else { return }
            runs = (try? await api.routineRuns(id: routine.id)) ?? []
        }
    }
}

/// What the bot did on its own, newest first, like Grok Bot's task list: a dot until it is read,
/// « Fait » once dealt with. Touching one opens its conversation, where the reply is.
struct BotRunsSection: View {
    @Environment(ChatStore.self) private var store
    let assistantID: String
    let onOpen: (UUID) -> Void
    @State private var runs: [BotRun] = []
    @State private var showsDone = false

    private var shown: [BotRun] { showsDone ? runs : runs.filter { !$0.done } }

    var body: some View {
        Section {
            if runs.isEmpty {
                Text("Pas encore passé tout seul.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(shown.prefix(10)) { run in
                    Button {
                        open(run)
                    } label: {
                        row(run)
                    }
                    .tint(.primary)
                    .swipeActions {
                        Button(run.done ? "À refaire" : "Fait", systemImage: run.done ? "arrow.uturn.backward" : "checkmark") {
                            mark(run, done: !run.done)
                        }
                        .tint(run.done ? .gray : .green)
                    }
                    .swipeActions(edge: .leading) {
                        if !run.done {
                            Button(run.seen ? "Non lu" : "Lu", systemImage: run.seen ? "circle.fill" : "envelope.open") {
                                mark(run, seen: !run.seen)
                            }
                            .tint(.accentColor)
                        }
                    }
                }
            if runs.contains(where: \.done) {
                Toggle("Montrer ce qui est fait", isOn: $showsDone).font(.subheadline)
            }
        } header: {
            let unread = runs.filter { !$0.seen }.count
            Text(unread == 0 ? "Ce qu'il a fait" : "Ce qu'il a fait · \(unread) à lire")
        } footer: {
            Text("Ses passages tout seul (routines, tâche permanente). Glisse vers la gauche pour « Fait ».")
        }
        .task { await load() }
    }

    private func row(_ run: BotRun) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(run.seen ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.title)
                    .font(.subheadline.weight(run.seen ? .regular : .semibold))
                    .strikethrough(run.done)
                Text(run.status == "failed" ? "Échec · \(run.error)" : run.status == "running" ? "En cours" : run.task ? "Tâche permanente" : "Routine")
                    .font(.caption)
                    .foregroundStyle(run.status == "failed" ? .red : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(run.at, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .opacity(run.done ? 0.5 : 1)
    }

    private func load() async {
        guard let api = store.settings.api else { return }
        runs = (try? await api.botRuns(assistantID: assistantID)) ?? runs
    }

    private func open(_ run: BotRun) {
        if !run.seen { mark(run, seen: true) }
        if let id = UUID(uuidString: run.conversationID) { onOpen(id) }
    }

    private func mark(_ run: BotRun, seen: Bool? = nil, done: Bool? = nil) {
        guard let index = runs.firstIndex(where: { $0.id == run.id }) else { return }
        if let seen { runs[index].seen = seen }
        if let done {
            runs[index].done = done
            if done { runs[index].seen = true }
        }
        Task {
            guard let api = store.settings.api else { return }
            if let saved = try? await api.markRun(id: run.id, seen: seen, done: done),
               let index = runs.firstIndex(where: { $0.id == saved.id }) {
                runs[index] = saved
            }
        }
    }
}
