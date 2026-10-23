import SwiftUI

struct ComposerView: View {
    @Environment(ChatStore.self) private var store
    var focused: FocusState<Bool>.Binding

    var body: some View {
        @Bindable var store = store
        HStack(alignment: .bottom, spacing: 6) {
            Menu {
                // Capture arrives in a later milestone; shown so the layout is final.
                Section("Bientôt") {
                    Button("Photo", systemImage: "photo") {}.disabled(true)
                    Button("Appareil photo", systemImage: "camera") {}.disabled(true)
                    Button("Fichier", systemImage: "doc") {}.disabled(true)
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
            }
            .tint(.secondary)
            .accessibilityLabel("Ajouter")

            TextField("Message", text: $store.draft, axis: .vertical)
                .lineLimit(1...8)
                .focused(focused)
                .padding(.vertical, 8)

            if store.isStreaming {
                Button("Arrêter", systemImage: "stop.fill") { store.stop() }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.primary, in: .circle)
                    .padding(2)
            } else if store.canSend {
                Button("Envoyer", systemImage: "arrow.up") { store.send() }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor, in: .circle)
                    .padding(2)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .background(Theme.surface, in: .rect(cornerRadius: 24))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 3)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .animation(.snappy(duration: 0.2), value: store.canSend)
    }
}
