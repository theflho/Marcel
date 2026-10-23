import SwiftUI

struct SettingsView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var testing = false
    @State private var addingServer = false
    @State private var confirmingEmergency = false
    @State private var resuming = false
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.system
    @State private var path: [SettingsRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    HStack(spacing: 12) {
                        MarcelAvatar(size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.settings.active.name)
                                .font(.body.weight(.semibold))
                                .lineLimit(1)
                            Text(store.settings.active.url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        ServerStatusBadge(status: store.serverStatus)
                            .font(.subheadline.weight(.medium))
                    }
                    Button {
                        testing = true
                        Task {
                            await store.checkServer()
                            testing = false
                        }
                    } label: {
                        HStack {
                            Text("Tester la connexion")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(testing)
                } header: {
                    Text("Connexion")
                }

                if store.models.count > 1 {
                    Section {
                        Picker("Modèle", selection: Binding(
                            get: { store.selectedModel ?? store.models[0] },
                            set: { store.selectModel($0) }
                        )) {
                            ForEach(store.models) { model in
                                Text(model.label).tag(model)
                            }
                        }
                    } header: {
                        Text("Modèle")
                    } footer: {
                        Text("Modèle utilisé par défaut sur ce serveur. Tu peux aussi le changer depuis la barre de message.")
                    }
                }

                Section {
                    Picker("Thème", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Apparence")
                }

                DeviceSection()

                Section {
                    if store.emergencyActive {
                        Button {
                            resuming = true
                            Task {
                                await store.emergencyResume()
                                resuming = false
                            }
                        } label: {
                            HStack {
                                Label("Reprendre", systemImage: "play.circle.fill")
                                Spacer()
                                if resuming { ProgressView() }
                            }
                        }
                        .disabled(resuming)
                    } else {
                        Button(role: .destructive) {
                            confirmingEmergency = true
                        } label: {
                            Label("Arrêt d'urgence", systemImage: "exclamationmark.octagon.fill")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("Sécurité")
                } footer: {
                    Text(store.emergencyActive
                         ? "Arrêt d'urgence actif : l'app n'envoie plus aucune requête et le serveur refuse toute nouvelle mission."
                         : "Coupe immédiatement toutes les missions en cours sur le serveur, bloque les nouvelles et arrête toutes les requêtes de l'app, jusqu'à ce que tu reprennes.")
                }

                Section {
                    NavigationLink {
                        MemoryView()
                    } label: {
                        Label("Mémoire de Marcel", systemImage: "brain")
                    }
                    .disabled(store.emergencyActive)
                    NavigationLink {
                        GoalsView()
                    } label: {
                        Label("Objectifs suivis", systemImage: "scope")
                    }
                    .disabled(store.emergencyActive)
                    NavigationLink {
                        ProactiveSettingsView()
                    } label: {
                        Label("Marcel proactif", systemImage: "lightbulb")
                    }
                    .disabled(store.emergencyActive)
                } header: {
                    Text("Mémoire")
                } footer: {
                    Text("Ce que Marcel retient de vous, sur le serveur actif : un noyau envoyé à chaque mission et des archives sans limite, rangés chaque nuit. Les objectifs suivis sont vérifiés automatiquement selon les réglages de Marcel proactif.")
                }

                Section {
                    ForEach(store.settings.profiles) { profile in
                        NavigationLink {
                            ServerEditView(profile: profile)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name)
                                    Text(profile.url)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                if profile.id == store.settings.activeID {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                        .accessibilityLabel("Serveur actif")
                                }
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if profile.id != store.settings.activeID {
                                Button("Utiliser", systemImage: "checkmark.circle") { store.useServer(profile) }
                                    .tint(.accentColor)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            if store.settings.profiles.count > 1 {
                                Button("Supprimer", systemImage: "trash", role: .destructive) {
                                    removeServer(profile)
                                }
                            }
                        }
                    }
                    Button("Ajouter un serveur", systemImage: "plus") { addingServer = true }
                } header: {
                    Text("Serveurs")
                } footer: {
                    Text("Touche un serveur pour modifier son adresse et son jeton, ou balaie vers la droite pour l'utiliser. Les conversations restent sur l'iPhone quand tu changes de serveur.")
                }

                Section {
                    LabeledContent("Version", value: Self.appVersion)
                } header: {
                    Text("À propos")
                } footer: {
                    Text("Les jetons sont stockés dans le trousseau de l'iPhone. Aucune clé Hermes ou Scaleway n'est conservée dans l'app.")
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .emergencyConfirmation(isPresented: $confirmingEmergency)
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .server(let id):
                    if let profile = store.settings.profiles.first(where: { $0.id == id }) {
                        ServerEditView(profile: profile)
                    }
                case .proactive:
                    ProactiveSettingsView()
                }
            }
            .onAppear {
                // Opened from an error or the token gauge: go straight to the screen concerned.
                if let route = store.settingsRequest {
                    path = [route]
                    store.settingsRequest = nil
                }
            }
            .sheet(isPresented: $addingServer) {
                NavigationStack {
                    ServerEditView(profile: nil)
                }
            }
        }
    }

    private func removeServer(_ profile: ServerProfile) {
        let wasActive = profile.id == store.settings.activeID
        store.settings.remove(profile)
        if wasActive { Task { await store.checkServer() } }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// Edits a saved server, or creates one when `profile` is nil.
struct ServerEditView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let profile: ServerProfile?

    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var testResult: ServerStatus = .unknown
    @State private var loaded = false

    private var draft: ServerProfile {
        ServerProfile(id: profile?.id ?? UUID(), name: name, url: url)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && draft.baseURL != nil
    }

    var body: some View {
        Form {
            Section {
                TextField("Nom", text: $name)
                TextField("https://…ts.net", text: $url)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Serveur")
            } footer: {
                if !url.isEmpty && draft.baseURL == nil {
                    Text("Adresse invalide : elle doit commencer par https:// ou http://.")
                        .foregroundStyle(.red)
                } else {
                    Text("Adresse du backend Marcel dans ton réseau Tailscale.")
                }
            }

            Section {
                SecureField("Jeton d'accès", text: $token)
                    // Keeps iOS from offering to save the token as a password.
                    .textContentType(.oneTimeCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Authentification")
            } footer: {
                Text("Le jeton défini par MARCEL_TOKEN sur le serveur. Stocké dans le trousseau.")
            }

            Section {
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        Text("Tester ce serveur")
                        Spacer()
                        if testResult == .checking {
                            ProgressView()
                        } else {
                            ServerStatusBadge(status: testResult)
                        }
                    }
                }
                .disabled(!isValid || testResult == .checking)

                if let profile, profile.id != store.settings.activeID {
                    Button("Utiliser ce serveur") {
                        save()
                        store.useServer(profile)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }

            if let profile, store.settings.profiles.count > 1 {
                Section {
                    Button("Supprimer ce serveur", role: .destructive) {
                        let wasActive = profile.id == store.settings.activeID
                        store.settings.remove(profile)
                        if wasActive { Task { await store.checkServer() } }
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(profile == nil ? "Nouveau serveur" : name.isEmpty ? "Serveur" : name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if profile == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ajouter") {
                        save()
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
        .onAppear {
            guard !loaded, let profile else { return }
            loaded = true
            name = profile.name
            url = profile.url
            token = store.settings.token(for: profile)
        }
        // Existing servers save as you leave the screen, like the Settings app.
        .onDisappear {
            if profile != nil, isValid { save() }
        }
        .onChange(of: url) { testResult = .unknown }
        .onChange(of: token) { testResult = .unknown }
    }

    private func save() {
        let trimmed = ServerProfile(id: draft.id,
                                    name: name.trimmingCharacters(in: .whitespaces),
                                    url: url.trimmingCharacters(in: .whitespacesAndNewlines))
        let saved: ServerProfile
        if profile == nil {
            saved = store.settings.add(name: trimmed.name, url: trimmed.url)
        } else {
            store.settings.update(trimmed)
            saved = trimmed
        }
        let tokenChanged = store.settings.token(for: saved) != token.trimmingCharacters(in: .whitespacesAndNewlines)
        store.settings.setToken(token, for: saved)
        if saved.id == store.settings.activeID, tokenChanged || profile?.url != saved.url {
            Task { await store.checkServer() }
        }
    }

    private func test() async {
        guard let baseURL = draft.baseURL else { return }
        testResult = .checking
        let api = MarcelAPI(baseURL: baseURL, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        testResult = switch await api.health()?.status {
        case 200: .reachable
        case 401, 403: .unauthorized
        default: .unreachable
        }
    }
}

/// What happens on the iPhone itself: voice, notifications, and what it shares with Marcel.
private struct DeviceSection: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.openURL) private var openURL
    @AppStorage(Speaker.autoReadKey) private var readAloud = false
    @State private var notifications = BackgroundRefresh.isEnabled
    @State private var calendar = UserDefaults.standard.bool(forKey: Agenda.shareKey) && Agenda.isAuthorized
    @State private var workReminders = WorkReminders.isEnabled
    @State private var refused: String?

    var body: some View {
        Section {
            Toggle("Lire les réponses à voix haute", isOn: $readAloud)
            Toggle("Notifications", isOn: $notifications)
                .onChange(of: notifications) { _, wanted in
                    Task {
                        let on = await BackgroundRefresh.setEnabled(wanted)
                        if wanted && !on {
                            notifications = false
                            refused = "Les notifications sont refusées pour Marcel dans les réglages de l'iPhone."
                        }
                    }
                }
            Toggle("Rappels de pointage (5 min avant)", isOn: $workReminders)
                .onChange(of: workReminders) { _, wanted in
                    Task {
                        let on = await WorkReminders.setEnabled(wanted)
                        if wanted && !on {
                            workReminders = false
                            refused = "Les notifications sont refusées pour Marcel dans les réglages de l'iPhone."
                        } else if on {
                            await store.syncPlanning(force: true)
                        }
                    }
                }
            Toggle("Partager mon agenda", isOn: $calendar)
                .onChange(of: calendar) { _, wanted in
                    Task {
                        let on = wanted ? await Agenda.requestAccess() : false
                        UserDefaults.standard.set(on, forKey: Agenda.shareKey)
                        if wanted && !on {
                            calendar = false
                            refused = "L'accès à l'agenda est refusé pour Marcel dans les réglages de l'iPhone."
                        }
                    }
                }
            if let refused {
                VStack(alignment: .leading, spacing: 8) {
                    Label(refused, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Button("Ouvrir les réglages de l'iPhone") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .font(.footnote.weight(.semibold))
                }
            }
        } header: {
            Text("Sur cet iPhone")
        } footer: {
            Text("La voix est celle de l'iPhone, sans Internet ; appui long sur une réponse pour l'écouter. "
                 + "Les notifications signalent les idées et les réponses terminées quand l'app est fermée ; iOS choisit le moment, souvent avec une heure de retard ou plus. "
                 + "L'agenda des 7 prochains jours accompagne tes messages, en lecture seule : Marcel ne peut rien y modifier. "
                 + "Les rappels de pointage suivent ton planning RMA lu par le serveur ; un appui ouvre le portail, et tu pointes toi-même sur place.")
        }
    }
}

struct ServerStatusBadge: View {
    let status: ServerStatus

    var body: some View {
        switch status {
        case .reachable: Label("Connecté", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .unauthorized: Label("Jeton refusé", systemImage: "key.slash").foregroundStyle(.red)
        case .unreachable: Label("Inaccessible", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case .checking: ProgressView()
        case .unknown: EmptyView()
        }
    }
}

extension View {
    /// Asks before the emergency stop, which cuts every mission at once.
    func emergencyConfirmation(isPresented: Binding<Bool>) -> some View {
        modifier(EmergencyConfirmation(isPresented: isPresented))
    }
}

private struct EmergencyConfirmation: ViewModifier {
    @Environment(ChatStore.self) private var store
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.confirmationDialog("Tout arrêter ?", isPresented: $isPresented, titleVisibility: .visible) {
            Button("Arrêt d'urgence", role: .destructive) { store.emergencyStop() }
        } message: {
            Text("Les missions en cours sont coupées sur le serveur et plus aucune requête n'est envoyée jusqu'à ce que tu reprennes.")
        }
    }
}
