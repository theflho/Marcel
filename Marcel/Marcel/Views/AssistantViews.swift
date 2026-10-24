import SwiftUI

/// Each assistant's own icon and colour, so they're told apart at a glance (Marcel keeps his avatar).
struct AssistantIcon: View {
    let id: String
    var size: CGFloat = 36

    private var symbol: String {
        switch id {
        case "planning": "calendar"
        case "pointage": "clock.badge.checkmark.fill"
        case "mails": "envelope.fill"
        case "veille": "lightbulb.max.fill"
        case "recrutements": "person.crop.circle.badge.plus"
        default: "sparkles"
        }
    }

    private var color: Color {
        switch id {
        case "planning": .orange
        case "pointage": .green
        case "mails": .blue
        case "veille": .yellow
        case "recrutements": .purple
        default: .purple
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: .circle)
            .accessibilityHidden(true)
    }
}

/// Top of an assistant's conversation: what it does, its settings and the instructions it keeps.
struct AssistantCard: View {
    @Environment(ChatStore.self) private var store
    let assistant: Assistant
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    AssistantIcon(id: assistant.id, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(assistant.summary)
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.leading)
                        Text(assistant.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(.rect)
            }
            .tint(.primary)
            .accessibilityHint(expanded ? "Masque les réglages" : "Affiche les réglages")

            if assistant.id == "recrutements" {
                OffersList(offers: store.offers)
            }

            if expanded {
                Divider()
                ForEach(assistant.settings) { setting in
                    HStack(alignment: .firstTextBaseline) {
                        Text(setting.label).font(.footnote)
                        Spacer()
                        Text(setting.shown(setting.value))
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                if !assistant.instructions.isEmpty {
                    Divider()
                    Text("Consignes retenues").font(.footnote.weight(.semibold))
                    ForEach(assistant.instructions) { instruction in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•").font(.footnote)
                            Text(instruction.text).font(.footnote)
                            Spacer(minLength: 0)
                            Button("Retirer", systemImage: "xmark.circle.fill") {
                                Task { await store.deleteInstruction(instruction, of: assistant) }
                            }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Pour changer un réglage, écris-le simplement : je te propose le changement, il ne s'applique que si tu appuies sur « Appliquer ».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Theme.surface, in: .rect(cornerRadius: 18))
        .padding(.horizontal)
    }
}

/// The offers: each with its hours, what it clashes with (the portal's warning, the planning, the
/// iPhone's calendar) and the week's load. "Accepter" / "Refuser" ask for a "Oui" first; the robot
/// then answers in the portal within 10 minutes.
private struct OffersList: View {
    @Environment(ChatStore.self) private var store
    let offers: [Offer]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            if offers.isEmpty {
                Text("Aucune offre en attente.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(offers) { offer in
                OfferCard(offer: offer, missions: store.planningMissions)
            }
            Link(destination: Offer.portalURL) {
                Label("Ouvrir les recrutements dans le portail", systemImage: "arrow.up.right.square")
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

    private var assistant: Assistant? {
        store.conversations.first { $0.messages.contains { $0.id == message.id } }.flatMap(store.assistant(for:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(proposal.resume.isEmpty ? "Changement proposé" : proposal.resume, systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
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
            switch message.proposalDecision {
            case "applied"?:
                Label("Appliqué", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green)
            case "cancelled"?:
                Label("Annulé", systemImage: "xmark.circle").font(.footnote).foregroundStyle(.secondary)
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
                    Button("Annuler") { store.cancelProposal(message.id) }
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
