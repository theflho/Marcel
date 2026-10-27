import SwiftUI

/// The offers: each with its hours, what it clashes with (the portal's warning, the planning, the
/// iPhone's calendar) and the week's load. "Accepter" / "Refuser" ask for a "Oui" first; the robot
/// then answers in the portal within 10 minutes.
struct OffersList: View {
    @Environment(ChatStore.self) private var store
    let offers: [Offer]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if offers.isEmpty {
                Text("Aucune offre en attente.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(offers) { offer in
                OfferCard(offer: offer, missions: store.planningMissions)
            }
            Link(destination: Offer.portalURL) {
                Label("Ouvrir les offres dans le portail RMA", systemImage: "arrow.up.right.square")
                    .font(.footnote.weight(.semibold))
            }
        }
    }
}

private struct OfferCard: View {
    @Environment(ChatStore.self) private var store
    let offer: Offer
    let missions: [PlanningMission]
    @State private var confirming: Bool?
    @State private var sending = false

    private var dayText: String {
        let day = offer.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        guard let start = offer.startAt, let end = offer.endAt else { return day }
        return "\(day) · \(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
    }

    /// The user's own events at those hours (or that day), from the iPhone's calendar.
    private var agenda: [String] {
        let start = offer.startAt ?? offer.day
        let end = offer.endAt ?? offer.day.addingTimeInterval(86_399)
        return Agenda.clashes(from: start, to: end)
    }

    /// Missions already planned in the offer's week, and their hours.
    private var week: (count: Int, hours: Double) {
        let calendar = Calendar.current
        let same = missions.filter { calendar.isDate($0.startAt, equalTo: offer.day, toGranularity: .weekOfYear) }
        return (same.count, same.reduce(0) { $0 + $1.endAt.timeIntervalSince($1.startAt) } / 3600)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(dayText).font(.footnote.weight(.semibold))
            Text(offer.store).font(.subheadline.weight(.semibold))
            Text([offer.kind, offer.client].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)

            if offer.past {
                note("clock.badge.xmark", "Date passée", .secondary)
            }
            if let dayNote = offer.dayNote, !dayNote.isEmpty {
                note("calendar.badge.exclamationmark", dayNote, .purple)
            }
            if !offer.portalConflict.isEmpty {
                note("exclamationmark.octagon.fill", offer.portalConflict, .red)
            }
            if !offer.conflict.isEmpty {
                note("exclamationmark.triangle.fill", capitalized(offer.conflict), .orange)
            }
            ForEach(agenda, id: \.self) { event in
                note("calendar.badge.exclamationmark", "Agenda : \(event)", .orange)
            }
            if offer.portalConflict.isEmpty && offer.conflict.isEmpty && agenda.isEmpty && !offer.past {
                note("checkmark.circle.fill", "Libre", .green)
            }
            let load = week
            note("chart.bar.fill", load.count == 0 ? "Aucune mission cette semaine-là"
                 : "Cette semaine-là : \(load.count) mission(s), \(load.hours.formatted(.number.precision(.fractionLength(0...1)))) h",
                 .secondary)

            answerArea
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background, in: .rect(cornerRadius: 14))
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible) {
            Button(confirming == true ? "Oui, accepter" : "Oui, refuser", role: confirming == true ? nil : .destructive) {
                let accept = confirming == true
                sending = true
                Task {
                    await store.answer(offer, accept: accept)
                    sending = false
                }
            }
            Button("Non", role: .cancel) {}
        } message: {
            Text("Marcel répondra dans le portail RMA dans les 10 minutes, puis te dira si c'est fait.")
        }
    }

    private var confirmTitle: String {
        "\(confirming == true ? "Accepter" : "Refuser") la mission \(offer.store) du \(dayText) ?"
    }

    @ViewBuilder
    private var answerArea: some View {
        switch offer.answerStatus {
        case "pending":
            HStack {
                ProgressView().controlSize(.small)
                Text(offer.answer == "accept" ? "Acceptation en cours (10 min max)" : "Refus en cours (10 min max)")
                    .font(.caption)
                Spacer()
                Button("Annuler") { Task { await store.cancelAnswer(offer) } }
                    .font(.caption).buttonStyle(.bordered).controlSize(.small)
            }
        case "done":
            note(offer.answer == "accept" ? "checkmark.seal.fill" : "xmark.seal", offer.answerMessage,
                 offer.answer == "accept" ? .green : .secondary)
        default:
            if offer.answerStatus == "failed" {
                note("exclamationmark.circle", offer.answerMessage, .red)
            }
            if offer.status == "open" && !offer.past {
                if offer.canAnswer {
                    HStack {
                        Button("Refuser") { confirming = false }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button("Accepter la mission") { confirming = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                    .disabled(sending || store.emergencyActive)
                } else {
                    Text(offer.portalConflict.isEmpty
                         ? "Réponse possible seulement dans le portail pour l'instant."
                         : "Le portail bloque la réponse tant que ce conflit existe.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func note(_ symbol: String, _ text: String, _ color: Color) -> some View {
        Label {
            Text(text).font(.caption)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color).font(.caption)
        }
    }

    private func capitalized(_ text: String) -> String {
        String(text.prefix(1)).uppercased() + String(text.dropFirst())
    }
}

/// A change an assistant proposed, under its reply: nothing happens until "Appliquer".
struct ProposalCard: View {
    @Environment(ChatStore.self) private var store
    let message: ChatMessage
    let proposal: AssistantProposal
    @State private var applying = false

    /// The one named in the proposal (from Marcel's own conversations), else this conversation's.
    private var assistant: Assistant? {
        if let id = proposal.assistant { return store.assistants.first { $0.id == id } }
        return store.conversations.first { $0.messages.contains { $0.id == message.id } }.flatMap { store.assistant(for: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if proposal.assistant != nil, let assistant {
                HStack(spacing: 8) {
                    MarcelAvatar(size: 28, mood: store.mood(for: assistant))
                    Text(assistant.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            Label(proposal.resume.isEmpty ? "Changement proposé" : proposal.resume, systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
            ForEach(proposal.actions, id: \.self) { action in
                Label(AssistantProposal.label(ofAction: action), systemImage: "arrow.clockwise")
                    .font(.footnote)
            }
            ForEach(proposal.changes.keys.sorted(), id: \.self) { key in
                let setting = assistant?.setting(key)
                let value = proposal.changes[key]!
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(setting?.label ?? key)
                    Spacer()
                    if let setting {
                        Text(setting.shown(setting.value)).foregroundStyle(.secondary).strikethrough()
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(setting?.shown(value) ?? "\(value)").fontWeight(.medium)
                }
                .font(.footnote)
            }
            let consigne = proposal.consigne.trimmingCharacters(in: .whitespacesAndNewlines)
            if !consigne.isEmpty {
                Text("Consigne à retenir : « \(consigne) »").font(.footnote)
            }
            // Marcel applied it himself once his reply was complete: no button left to press.
            switch message.autoApplied("reglage") ? Optional("applied") : message.proposalDecision {
            case "applied"?:
                Label(message.autoApplied("reglage") ? "Fait par Marcel" : "Appliqué",
                      systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green)
            case "cancelled"?:
                Label("Refusé", systemImage: "hand.raised.slash").font(.footnote).foregroundStyle(.secondary)
            default:
                HStack {
                    Button {
                        applying = true
                        Task {
                            await store.applyProposal(message.id)
                            applying = false
                        }
                    } label: {
                        if applying { ProgressView().controlSize(.small) } else { Text("Appliquer") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(applying || store.emergencyActive)
                    // Like Grok Bot's "Always allow": settings changes then go to "Tout seul".
                    Button("Toujours") {
                        applying = true
                        Task {
                            await store.applyProposalAlways(message.id)
                            applying = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(applying || store.emergencyActive)
                    .accessibilityLabel("Toujours autoriser")
                    Button("Refuser", role: .destructive) { store.cancelProposal(message.id) }
                        .buttonStyle(.bordered)
                        .disabled(applying)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Theme.background, in: .rect(cornerRadius: 14))
    }
}

/// An assistant Marcel proposes to create: nothing is created until "Créer l'assistant".
struct NewAssistantCard: View {
    @Environment(ChatStore.self) private var store
    let message: ChatMessage
    let draft: AssistantDraft
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                MarcelAvatar(size: 44, mood: draft.mood)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nouvel assistant").font(.caption).foregroundStyle(.secondary)
                    Text(draft.nom).font(.headline)
                }
            }
            Text(draft.mission).font(.footnote)
            Text("Tu le choisiras comme mode d'une conversation. Il n'a aucun outil (ni web, ni envoi) : il conseille, rédige et prépare.")
                .font(.caption)
                .foregroundStyle(.secondary)
            switch message.autoApplied("assistant") ? Optional("applied") : message.proposalDecision {
            case "applied"?:
                Label("Assistant créé", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green)
            case "cancelled"?:
                Label("Pas créé", systemImage: "xmark.circle").font(.footnote).foregroundStyle(.secondary)
            default:
                HStack {
                    Button {
                        creating = true
                        Task {
                            await store.createAssistant(draft, from: message.id)
                            creating = false
                        }
                    } label: {
                        if creating { ProgressView().controlSize(.small) } else { Text("Créer l'assistant") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(creating || store.emergencyActive)
                    Button("Non merci") { store.cancelProposal(message.id) }
                        .buttonStyle(.bordered)
                        .disabled(creating)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Theme.background, in: .rect(cornerRadius: 14))
    }
}

/// Menu items to choose the illustration of Marcel that stands for an assistant.
struct AssistantMoodPicker: View {
    @Environment(ChatStore.self) private var store
    let assistant: Assistant

    var body: some View {
        Picker("Mascotte", selection: Binding(
            get: { store.mood(for: assistant) },
            set: { mood in Task { await store.setMood(mood, for: assistant) } }
        )) {
            ForEach(MarcelMood.allCases) { mood in
                Label {
                    Text(mood.label)
                } icon: {
                    Image(mood.imageName + "-cutout")
                }
                .tag(mood)
            }
        }
    }
}
