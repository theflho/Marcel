import SwiftUI

struct SettingsView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var testing = false

    var body: some View {
        @Bindable var settings = store.settings
        NavigationStack {
            Form {
                Section {
                    TextField("https://…ts.net", text: $settings.serverURL)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Serveur")
                } footer: {
                    Text("Adresse HTTPS du backend Marcel dans ton réseau Tailscale.")
                }

                Section {
                    SecureField("Jeton d'accès", text: $settings.token)
                        // Keeps iOS from offering to save the token as a password.
                        .textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Authentification")
                } footer: {
                    Text("Stocké dans le trousseau de l'iPhone. Aucune clé Hermes ou Scaleway n'est conservée dans l'app.")
                }

                Section {
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
                            if testing {
                                ProgressView()
                            } else {
                                statusLabel
                            }
                        }
                    }
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch store.serverStatus {
        case .reachable: Label("Connecté", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .unauthorized: Label("Jeton refusé", systemImage: "key.slash").foregroundStyle(.red)
        case .unreachable: Label("Inaccessible", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case .unknown, .checking: EmptyView()
        }
    }
}
