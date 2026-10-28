import SwiftUI

/// Tasks Marcel runs by himself at a fixed time, on the active server ("every Monday at 8, the
/// week ahead"). Each routine's replies arrive in its own conversation, with a notification.
struct RoutinesView: View {
    @Environment(ChatStore.self) private var store
    @State private var routines: [Routine] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var editing: Routine?
    @State private var adding = false
    @State private var actionError: String?
    @State private var notice: String?

    var body: some View {
        Group {
            if store.emergencyActive {
                ContentUnavailableView("Arrêt d'urgence actif", systemImage: "exclamationmark.octagon",
                                       description: Text("Aucune requête n'est envoyée au serveur. Reprends pour consulter les routines."))
            } else if let error, routines.isEmpty {
                ContentUnavailableView("Routines indisponibles", systemImage: "wifi.exclamationmark",
                                       description: Text(error))
            } else if loaded && routines.isEmpty {
                ContentUnavailableView {
                    Label("Aucune routine", systemImage: "alarm")
                } description: {
                    Text("Une tâche que Marcel fait seul à heure fixe : « chaque lundi à 8 h, le point de ma semaine », « chaque soir, résume mes e-mails ». Demande-la à Marcel ou ajoute-la ici.")
                } actions: {
                    Button("Ajouter une routine") { adding = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                list
            }
        }
        .navigationTitle("Routines")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Ajouter une routine", systemImage: "plus") { adding = true }
                    .disabled(store.emergencyActive)
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editing) { routine in
            RoutineEditor(routine: routine) { change in
                await perform { _ = try await $0.updateRoutine(id: routine.id, change) }
            }
        }
        .sheet(isPresented: $adding) {
            RoutineEditor(routine: nil) { change in
                await perform { _ = try await $0.addRoutine(change) }
            }
        }
        .alert("Échec", isPresented: .constant(actionError != nil)) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .alert("Routine lancée", isPresented: .constant(notice != nil)) {
            Button("OK") { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    private var list: some View {
        List {
            section("Actives", status: "active",
                    footer: "Marcel les lance seul, à l'heure du serveur, sans outil qui agit : il lit, résume et prépare, mais n'envoie ni n'achète rien. Le résultat arrive dans la conversation de la routine.")
            section("En pause", status: "paused")
        }
    }

    @ViewBuilder
    private func section(_ title: String, status: String, footer: String? = nil) -> some View {
        let matching = routines.filter { $0.status == status }
        if !matching.isEmpty {
            Section {
                ForEach(matching) { routine in
                    row(routine)
                }
            } header: {
                Text(title)
            } footer: {
                if let footer { Text(footer) }
            }
        }
    }

    private func row(_ routine: Routine) -> some View {
        Button {
            editing = routine
        } label: {
            RoutineSummary(routine: routine)
        }
        .tint(.primary)
        .swipeActions(edge: .leading) {
            Button("Lancer", systemImage: "play.fill") { Task { await run(routine) } }
                .tint(.blue)
            if routine.status == "active" {
                Button("Pause", systemImage: "pause.fill") {
                    Task { await perform { _ = try await $0.updateRoutine(id: routine.id, RoutineChange(status: "paused")) } }
                }
                .tint(.orange)
            } else {
                Button("Reprendre", systemImage: "arrow.clockwise") {
                    Task { await perform { _ = try await $0.updateRoutine(id: routine.id, RoutineChange(status: "active")) } }
                }
                .tint(.accentColor)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Supprimer", systemImage: "trash", role: .destructive) {
                Task { await perform { try await $0.deleteRoutine(id: routine.id) } }
            }
        }
    }

    private func run(_ routine: Routine) async {
        guard !store.emergencyActive, let api = store.settings.api else { return }
        do {
            _ = try await api.runRoutine(id: routine.id)
            notice = "Marcel s'en occupe. Le résultat arrivera dans la conversation « \(routine.title) »."
            // The reply takes a little while: bring it in as soon as it's there.
            Task {
                for wait in [15.0, 30, 60] {
                    try? await Task.sleep(for: .seconds(wait))
                    await store.importRoutineRuns()
                }
            }
        } catch {
            actionError = error.localizedDescription
        }
        await load()
    }

    private func load() async {
        guard !store.emergencyActive, let api = store.settings.api else { return }
        do {
            routines = try await api.routines()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func perform(_ action: (MarcelAPI) async throws -> Void) async {
        guard !store.emergencyActive, let api = store.settings.api else { return }
        do {
            try await action(api)
        } catch {
            actionError = error.localizedDescription
        }
        await load()
    }
}

/// Title, schedule and last run of a routine.
private struct RoutineSummary: View {
    let routine: Routine

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(routine.title)
                .font(.body.weight(.medium))
            Text(routine.prompt)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 10) {
                Label(routine.schedule, systemImage: "alarm")
                if let run = routine.lastRun {
                    Label {
                        Text("\(run.status == "failed" ? "échec" : "passée") \(run.at, format: .relative(presentation: .named))")
                    } icon: {
                        Image(systemName: run.status == "failed" ? "exclamationmark.triangle" : "checkmark.circle")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct RoutineEditor: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let routine: Routine?
    let onSave: (RoutineChange) async -> Void
    @State private var title = ""
    @State private var prompt = ""
    @State private var days: Set<Int> = []
    @State private var time = Calendar.current.date(from: DateComponents(hour: 8, minute: 0)) ?? .now
    @State private var saving = false
    @State private var runs: [RoutineRun] = []
    @State private var when = When.hour
    @State private var sender = ""

    /// What starts it: the hour, or an event the server watches.
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

    private var trigger: String {
        when.takesSender ? when.rawValue + sender.trimmingCharacters(in: .whitespaces) : when.rawValue
    }

    private static let dayLetters = ["L", "M", "M", "J", "V", "S", "D"]
    private static let dayNames = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Ex. Point de la semaine", text: $title)
                    TextField("Ce que Marcel fera à chaque fois : résumer mon planning, mes objectifs…",
                              text: $prompt, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Routine")
                }
                Section {
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
                } header: {
                    Text("Quand")
                } footer: {
                    if when == .box || when == .boxSender {
                        Text("Le serveur regarde la boîte de Marcel chaque minute : crée sur le site un compte à son adresse et actives-y l'alerte. Les e-mails sont lus par un modèle sans outil : il te prévient avec le lien, et tu lui dis « Vas-y » pour qu'il agisse.")
                    } else if when == .mail || when == .sender {
                        Text("Le serveur regarde tes e-mails toutes les 5 minutes. Ils sont lus par un modèle sans outil : il ne peut rien faire, seulement te prévenir. Si rien ne compte, tu n'es pas dérangé.")
                    } else if when != .hour {
                        Text("Après chaque lecture du robot RMA qui trouve du nouveau.")
                    }
                }
                if when == .hour { Section {
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
                } header: {
                    Text("Jours et heure")
                } footer: {
                    Text(days.isEmpty ? "Aucun jour choisi : tous les jours." : "Heure du serveur. Si le serveur était éteint, la routine part à son retour, jusqu'à 3 h plus tard.")
                } }
                if !runs.isEmpty {
                    Section("Derniers passages") {
                        ForEach(runs.prefix(5)) { run in
                            HStack {
                                Text(run.status == "done" ? "Faite" : run.status == "running" ? "En cours" : "Échec")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text(run.at, format: .relative(presentation: .named))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(routine == nil ? "Nouvelle routine" : "Modifier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        saving = true
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
                        let change = RoutineChange(
                            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                            days: days.sorted().map(String.init).joined(separator: ","),
                            at: String(format: "%02d:%02d", parts.hour ?? 8, parts.minute ?? 0),
                            trigger: trigger)
                        Task {
                            await onSave(change)
                            dismiss()
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).count < 2
                              || prompt.trimmingCharacters(in: .whitespaces).count < 3 || saving
                              || (when.takesSender && sender.trimmingCharacters(in: .whitespaces).count < 2))
                }
            }
            .onAppear {
                guard let routine else { return }
                title = routine.title
                prompt = routine.prompt
                days = routine.weekdays
                if let kind = [When.sender, .boxSender].first(where: { routine.trigger.hasPrefix($0.rawValue) }) {
                    when = kind
                    sender = String(routine.trigger.dropFirst(kind.rawValue.count))
                } else {
                    when = When(rawValue: routine.trigger) ?? .hour
                }
                let parts = routine.at.split(separator: ":").compactMap { Int($0) }
                if parts.count == 2, let date = Calendar.current.date(from: DateComponents(hour: parts[0], minute: parts[1])) {
                    time = date
                }
            }
            .task {
                guard let routine, !store.emergencyActive, let api = store.settings.api else { return }
                runs = (try? await api.routineRuns(id: routine.id)) ?? []
            }
        }
        .presentationDetents([.large])
    }
}
