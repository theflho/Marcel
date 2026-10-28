import SwiftUI

struct TokenBudgetView: View {
    @Environment(ChatStore.self) private var store
    @State private var usage: TokenUsage?
    @State private var budgetText = ""
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?
    @State private var saved = false
    @FocusState private var editing: Bool

    private var proposedBudget: Int? {
        guard let value = Int(budgetText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...1_000_000_000).contains(value) else { return nil }
        return value
    }

    var body: some View {
        Form {
            if let usage {
                Section("Aujourd’hui") {
                    LabeledContent("Tokens utilisés", value: usage.today.formatted())
                    LabeledContent("Limite en vigueur", value: usage.budget.formatted())
                    ProgressView(value: usage.fraction)
                        .tint(usage.fraction >= 1 ? .red : .accentColor)
                }
                Section {
                    TextField("Tokens par jour", text: $budgetText)
                        .keyboardType(.numberPad)
                        .focused($editing)
                        .accessibilityLabel("Limite quotidienne de tokens")
                        .disabled(saving || store.emergencyActive)
                    if proposedBudget == nil {
                        Text("Entre un nombre entier de 1 à 1 000 000 000.")
                            .font(.footnote).foregroundStyle(.orange)
                    } else if let proposedBudget, proposedBudget <= usage.today {
                        Text("La consommation du jour atteint déjà ce plafond. Les prochains appels au modèle seront bloqués jusqu’à minuit, ou jusqu’à ce que tu relèves la limite.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    Button {
                        editing = false
                        Task { await save() }
                    } label: {
                        HStack {
                            Text("Enregistrer")
                            Spacer()
                            if saving { ProgressView() }
                        }
                    }
                    .disabled(proposedBudget == nil || proposedBudget == usage.budget || saving || loading || store.emergencyActive)
                } header: {
                    Text("Limite quotidienne")
                } footer: {
                    Text("Partagée par Hermes sur Marcel et Telegram, ainsi que les vérifications automatiques. Le changement est immédiat, conservé les jours suivants et ne remet pas la consommation à zéro. Le compteur repart à minuit, heure du serveur. Les modèles renfort gardent leur propre budget.")
                }
                if saved { Label("Limite enregistrée", systemImage: "checkmark.circle").foregroundStyle(.green) }
            }
            if loading { ProgressView("Chargement…") }
            if let error {
                Section {
                    Text(error).foregroundStyle(.orange)
                    Button("Actualiser") { Task { await load() } }
                        .disabled(loading || saving || store.emergencyActive)
                }
            }
        }
        .navigationTitle("Tokens et limite")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.settings.activeID) { await load() }
        .refreshable { await load() }
        .onChange(of: budgetText) { _, _ in saved = false }
    }

    private func load() async {
        guard !store.emergencyActive, !saving, let api = store.settings.api else { return }
        let serverID = store.settings.activeID
        loading = true
        error = nil
        defer { loading = false }
        do {
            let result = try await api.tokenBudget()
            guard !Task.isCancelled, serverID == store.settings.activeID else { return }
            usage = result
            budgetText = String(result.budget)
            store.updateTokenUsage(result, serverID: serverID)
        } catch {
            guard !Task.isCancelled, serverID == store.settings.activeID else { return }
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        guard !store.emergencyActive, !saving, let budget = proposedBudget, let api = store.settings.api else { return }
        let serverID = store.settings.activeID
        saving = true
        error = nil
        saved = false
        defer { saving = false }
        do {
            let result = try await api.setTokenBudget(budget)
            guard serverID == store.settings.activeID else { return }
            usage = result
            store.updateTokenUsage(result, serverID: serverID)
            saved = true
        } catch {
            guard serverID == store.settings.activeID else { return }
            self.error = error.localizedDescription
        }
    }
}
