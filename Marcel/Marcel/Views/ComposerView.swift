import PhotosUI
import SwiftUI

struct ComposerView: View {
    @Environment(ChatStore.self) private var store
    var focused: FocusState<Bool>.Binding

    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showFileImporter = false

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            if !store.pendingAttachments.isEmpty || store.isPreparingAttachment {
                PendingAttachmentsStrip()
            }
            HStack(alignment: .bottom, spacing: 6) {
                Menu {
                    Button("Photothèque", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
                    Button("Appareil photo", systemImage: "camera") { showCamera = true }
                        .disabled(!CameraPicker.isAvailable)
                    Button("Fichier", systemImage: "doc") { showFileImporter = true }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                }
                .tint(.secondary)
                .accessibilityLabel("Ajouter une photo ou un fichier")

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
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        }
        .background(Theme.surface, in: .rect(cornerRadius: 24))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 3)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .animation(.snappy(duration: 0.2), value: store.canSend)
        .animation(.snappy(duration: 0.2), value: store.pendingAttachments)
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, maxSelectionCount: 6, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await store.addImage(data)
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in
                Task { await store.addImage(data) }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                for url in urls { await store.addFile(at: url) }
            }
        }
    }
}
