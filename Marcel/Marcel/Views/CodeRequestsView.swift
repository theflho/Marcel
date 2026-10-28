import SwiftUI

/// Marcel's own code: what he changed, merged and deployed himself, and the bigger requests the
/// user sent to a coding agent, Claude Code or Codex (each one a GitHub issue, then a pull request).
struct CodeRequestsView: View {
    @Environment(ChatStore.self) private var store
    /// The chosen agent's name, for the button under Marcel's requests.
    @AppStorage("codeAgentName") private var agentName = "Claude Code"
    /// "marcel" (he codes it himself), "claude" or "codex".
    @AppStorage("codeAgentID") private var agentID = "marcel"
    @State private var list: CodeRequestList?
    @State private var log: [CodeLogEntry] = []
    @State private var error: String?
    @State private var revertError: String?

    var body: some View {
        Group {
            if store.emergencyActive {
                ContentUnavailableView("Arrêt d'urgence actif", systemImage: "exclamationmark.octagon",
                                       description: Text("Aucune requête n'est envoyée au serveur."))
            } else if let error, list == nil {
                ContentUnavailableView("Demandes indisponibles", systemImage: "wifi.exclamationmark",
                                       description: Text(error))
            } else if let list, !list.configured {
                ContentUnavailableView("Pas encore branché", systemImage: "hammer",
                                       description: Text("Sur le serveur, règle MARCEL_GITHUB_REPO et MARCEL_GITHUB_TOKEN (clé GitHub limitée au dépôt de l'app : contenu, issues et pull requests), puis deploy/auto-update.sh dans la crontab."))
            } else if let list {
                List {
                    if let agents = list.agents, agents.count > 1 {
                        Section {
                            Picker("Agent", selection: agentBinding(list)) {
                                ForEach(agents) { agent in
                                    Text(agent.name).tag(agent.id)
                                }
                            }
                        } header: {
                            Text("Qui fait les gros chantiers")
                        } footer: {
                            Text(list.agent == "marcel"
                                 ? "Hermes code tout lui-même, même les gros chantiers, en plusieurs pull requests s'il le faut : rien à configurer."
                                 : "Hermes modifie son code lui-même. Pour un gros chantier, il peut préparer une demande que tu envoies à cet agent, sur GitHub. Sur le dépôt : secret ANTHROPIC_API_KEY pour Claude Code, OPENAI_API_KEY pour Codex.")
                        }
                    }
                    if list.requests.isEmpty, log.isEmpty {
                        Section {
                            Text("Rien pour l'instant. Dis à Hermes ce qui manque à l'app ou ce qui ne marche pas : il modifie son code lui-même, ouvre la pull request et attend ton accord pour la fusionner après les vérifications ; le serveur se met ensuite à jour seul.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !log.isEmpty {
                        Section {
                            ForEach(log) { entry in
                                CodeLogRow(entry: entry) { number in await revert(number) }
                            }
                        } header: {
                            Text("Ce que Hermes a fait")
                        } footer: {
                            Text("Après une fusion, le serveur se met à jour seul en quelques minutes et revient à la version précédente s'il ne répond plus. Un changement de l'app iPhone se compile dans Xcode.")
                        }
                    }
                    if !list.requests.isEmpty {
                        Section {
                            ForEach(list.requests) { request in
                                CodeRequestRow(request: request)
                            }
                        } header: {
                            Text("Demandes aux agents de code")
                        } footer: {
                            Text("L'agent prépare chaque demande sur une branche de \(list.repo) et ouvre une pull request, que tu relis et fusionnes sur GitHub.")
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Code de l’app")
        .alert("Annulation impossible", isPresented: Binding { revertError != nil } set: { if !$0 { revertError = nil } }) {
            Button("OK") {}
        } message: {
            Text(revertError ?? "")
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func revert(_ number: Int) async {
        guard let api = store.settings.api else { return }
        do {
            _ = try await api.revertCode(number: number)
            await load()
        } catch {
            revertError = error.localizedDescription
        }
    }

    private func agentBinding(_ list: CodeRequestList) -> Binding<String> {
        Binding {
            list.agent ?? "marcel"
        } set: { agent in
            guard let api = store.settings.api else { return }
            Task {
                do {
                    try await api.setCodeAgent(agent)
                    await load()
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func load() async {
        guard !store.emergencyActive, let api = store.settings.api else { return }
        do {
            let list = try await api.codeRequests()
            self.list = list
            if let name = list.agents?.first(where: { $0.id == list.agent })?.name {
                agentName = name.replacingOccurrences(of: " (OpenAI)", with: "")
            }
            agentID = list.agent ?? "marcel"
            log = (try? await api.codeLog().entries) ?? []
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct CodeLogRow: View {
    let entry: CodeLogEntry
    let revert: (Int) async -> Void
    @State private var confirming = false
    @State private var reverting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(entry.action.prefix(1).uppercased() + entry.action.dropFirst(), systemImage: icon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(color)
                Spacer()
                Text(entry.at, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(entry.detail).font(.subheadline).textSelection(.enabled)
            HStack(spacing: 16) {
                if let link = entry.url, !link.isEmpty, let url = URL(string: link) {
                    Link("Voir la pull request", destination: url)
                }
                if entry.action == "fusionnée", entry.number != nil {
                    Button("Annuler", role: .destructive) { confirming = true }
                        .buttonStyle(.borderless)
                        .disabled(reverting)
                    if reverting { ProgressView().controlSize(.small) }
                }
            }
            .font(.footnote)
        }
        .padding(.vertical, 2)
        .confirmationDialog("Annuler cette fusion ?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Annuler la fusion", role: .destructive) {
                guard let number = entry.number else { return }
                reverting = true
                Task {
                    await revert(number)
                    reverting = false
                }
            }
        } message: {
            Text("Cette action demande à Hermes de revenir sur ce changement via une nouvelle pull request et sa fusion au vert ; le serveur se met ensuite à jour.")
        }
    }

    private var icon: String {
        switch entry.action {
        case "proposée": "arrow.triangle.pull"
        case "fusionnée": "arrow.triangle.merge"
        case "déployée": "checkmark.icloud"
        case "retour arrière", "annulée": "arrow.uturn.backward"
        default: "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch entry.action {
        case "déployée", "fusionnée": .green
        case "proposée": .primary
        default: .orange
        }
    }
}

private struct CodeRequestRow: View {
    let request: CodeRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(request.title).font(.body.weight(.medium))
            Text(request.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            HStack(spacing: 12) {
                Label(stateLabel, systemImage: stateIcon)
                    .foregroundStyle(request.state == "fusionnee" ? .green : .secondary)
                Text(request.createdAt, format: .relative(presentation: .named)).foregroundStyle(.secondary)
            }
            .font(.caption)
            HStack(spacing: 16) {
                if let pr = request.prURL, !pr.isEmpty, let url = URL(string: pr) {
                    Link("Voir la pull request", destination: url)
                }
                if let url = URL(string: request.issueURL), let number = request.issueNumber {
                    Link("Issue #\(number)", destination: url)
                }
            }
            .font(.footnote)
        }
        .padding(.vertical, 2)
    }

    private var stateLabel: String {
        switch request.state {
        case "pr": "Pull request à relire"
        case "fusionnee": "Fusionnée (déployée seule)"
        case "fermee": "Fermée"
        case "inconnu": "GitHub injoignable"
        default: request.agent == "codex" ? "Codex y travaille" : "Claude Code y travaille"
        }
    }

    private var stateIcon: String {
        switch request.state {
        case "pr": "arrow.triangle.pull"
        case "fusionnee": "checkmark.circle.fill"
        case "fermee": "xmark.circle"
        default: "hammer"
        }
    }
}

/// A request Marcel wrote under his reply: nothing leaves until "Envoyer à Claude Code" (or Codex,
/// as chosen in Réglages › Code de Marcel).
struct CodeRequestCard: View {
    @Environment(ChatStore.self) private var store
    @AppStorage("codeAgentName") private var agentName = "Claude Code"
    @AppStorage("codeAgentID") private var agentID = "marcel"
    let message: ChatMessage
    let draft: CodeRequestDraft
    @State private var sending = false
    @State private var sent: CodeRequest?

    /// Marcel codes it himself: the default (Réglages › Code de Marcel), and always from a bot's
    /// conversation, which hands it to Marcel instead of GitHub.
    private var bySelf: Bool { agentID == "marcel" || store.assistant(forMessage: message.id) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Demande de code", systemImage: "hammer")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text(draft.titre).font(.headline)
            Text(draft.demande).font(.footnote)
            Text(bySelf
                 ? "Hermes le code lui-même avec ses outils (branche, vérification, pull request, fusion après ton accord et CI verte), même si c'est gros."
                 : "Envoyée, elle devient une issue sur GitHub : \(agentName) prépare une pull request que tu relis et fusionnes toi-même.")
                .font(.caption)
                .foregroundStyle(.secondary)
            switch message.proposalDecision {
            case "applied"? where bySelf:
                Label("Demandé à Hermes", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            case nil where bySelf:
                HStack {
                    Button("Fais-le toi-même") { store.askMarcelToCode(draft, from: message.id) }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isStreaming || store.emergencyActive)
                    Button("Non merci") { store.cancelProposal(message.id) }
                        .buttonStyle(.bordered)
                }
                .controlSize(.small)
            case "applied"?:
                HStack {
                    Label("Envoyée", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                    if let sent, let url = URL(string: sent.issueURL), let number = sent.issueNumber {
                        Link("Issue #\(number)", destination: url).font(.footnote)
                    }
                }
            case "cancelled"?:
                Label("Pas envoyée", systemImage: "xmark.circle").font(.footnote).foregroundStyle(.secondary)
            default:
                HStack {
                    Button {
                        sending = true
                        Task {
                            sent = await store.sendCodeRequest(from: message.id)
                            sending = false
                        }
                    } label: {
                        if sending { ProgressView().controlSize(.small) } else { Text("Envoyer à \(agentName)") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sending || store.emergencyActive || message.missionID == nil)
                    Button("Non merci") { store.cancelProposal(message.id) }
                        .buttonStyle(.bordered)
                        .disabled(sending)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Theme.background, in: .rect(cornerRadius: 14))
    }
}

/// Under a bot's reply: what it can't do itself, passed to Marcel (who has the tools) on a tap.
struct HandoffCard: View {
    @Environment(ChatStore.self) private var store
    let message: ChatMessage
    let handoff: MarcelHandoff

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                MarcelAvatar(size: 26, bot: nil)
                Text("Pour Hermes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            Text(handoff.demande).font(.footnote)
            Text("Cet échange avec Hermes lisait des e-mails en mode protégé. Ce bouton ouvre une conversation ordinaire avec ses outils pour poursuivre la demande.")
                .font(.caption)
                .foregroundStyle(.secondary)
            switch message.proposalDecision {
            case "applied"?:
                Label("Demandé à Hermes", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            case "cancelled"?:
                Label("Pas demandé", systemImage: "xmark.circle").font(.footnote).foregroundStyle(.secondary)
            default:
                HStack {
                    Button("Demander à Hermes") { store.askMarcel(handoff, from: message.id) }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isStreaming || store.emergencyActive)
                    Button("Non merci") { store.cancelProposal(message.id) }
                        .buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Theme.background, in: .rect(cornerRadius: 14))
    }
}

/// Under a reply: an RMA automation to hand to another bot (or give back). Done only on « Confier »:
/// it is the user's own go-ahead, like in the bot's card.
struct HandOverCard: View {
    @Environment(ChatStore.self) private var store
    let message: ChatMessage
    let proposal: HandOverProposal
    @State private var working = false

    var body: some View {
        let target = store.bot(named: proposal.bot, in: message.id)
        // Its label and who does it now, from the bots' cards.
        let automation = store.assistants.lazy.compactMap { $0.automations?.first { $0.key == proposal.automatisme } }.first
        VStack(alignment: .leading, spacing: 10) {
            Label("Automatisme RMA", systemImage: "arrow.left.arrow.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            if let target, let automation {
                Text("Confier « \(automation.label) » à \(target.name) ?").font(.headline)
                Text(automation.owner == target.id
                     ? "C'est déjà \(target.name) qui le fait."
                     : "\(automation.ownerName) arrête de le faire, \(target.name) le fait avec les mêmes réglages. Tu pourras le reprendre dans la fiche du bot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                switch message.proposalDecision {
                case "applied"?:
                    Label("Confié à \(target.name)", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                case "cancelled"?:
                    Label("Pas confié", systemImage: "xmark.circle").font(.footnote).foregroundStyle(.secondary)
                default:
                    HStack {
                        Button {
                            working = true
                            Task {
                                await store.acceptHandOver(proposal, to: target, from: message.id)
                                working = false
                            }
                        } label: {
                            if working { ProgressView().controlSize(.small) } else { Text("Confier") }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(working || store.emergencyActive || automation.owner == target.id)
                        Button("Non merci") { store.cancelProposal(message.id) }
                            .buttonStyle(.bordered)
                            .disabled(working)
                    }
                    .controlSize(.small)
                }
            } else {
                Text("Cette proposition ne correspond à aucun bot ou automatisme connu : rien n'a changé.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Theme.background, in: .rect(cornerRadius: 14))
    }
}
