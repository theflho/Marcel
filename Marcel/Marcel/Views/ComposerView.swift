import PhotosUI
import SwiftUI

struct ComposerView: View {
    @Environment(ChatStore.self) private var store
    var focused: FocusState<Bool>.Binding

    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var dictation = Dictation()
    /// Text already in the field when dictation started; the transcript is appended to it.
    @State private var dictationBase = ""
    @State private var showVoiceMode = false

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 0) {
            if !store.pendingAttachments.isEmpty || store.isPreparingAttachment {
                PendingAttachmentsStrip()
            }
            TextField(store.emergencyActive ? "Arrêt d'urgence actif" : "Demander à Marcel…",
                      text: $store.draft, axis: .vertical)
                .lineLimit(1...8)
                .focused(focused)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)

            HStack(spacing: 8) {
                attachMenu
                if let error = dictation.error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if store.models.count > 1 {
                    modelMenu
                }
                micButton
                sendButton
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .glass(in: .rect(cornerRadius: 24), interactive: false)
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
        .fullScreenCover(isPresented: $showVoiceMode) {
            VoiceModeView()
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                for url in urls { await store.addFile(at: url) }
            }
        }
    }

    private var attachMenu: some View {
        Menu {
            Button("Photothèque", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
            Button("Appareil photo", systemImage: "camera") { showCamera = true }
                .disabled(!CameraPicker.isAvailable)
            Button("Fichier", systemImage: "doc") { showFileImporter = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
        }
        .tint(.secondary)
        .accessibilityLabel("Ajouter une photo ou un fichier")
    }

    /// The model, a small icon: its name is in the menu (and under each reply).
    private var modelMenu: some View {
        Menu {
            Picker("Modèle", selection: Binding(
                get: { store.selectedModel ?? store.models[0] },
                set: { store.selectModel($0) }
            )) {
                ForEach(store.models) { Text($0.label).tag($0) }
            }
        } label: {
            Image(systemName: "cpu")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
        }
        .tint(.secondary)
        .accessibilityLabel("Modèle : \(store.selectedModel?.label ?? "par défaut")")
    }

    private var micButton: some View {
        Button {
            if dictation.isRecording {
                dictation.stop()
            } else {
                dictationBase = store.draft
                Task {
                    await dictation.start { transcript in
                        let separator = dictationBase.isEmpty || transcript.isEmpty ? "" : " "
                        store.draft = dictationBase + separator + transcript
                    }
                }
            }
        } label: {
            Image(systemName: dictation.isRecording ? "waveform" : "mic")
                .font(.system(size: 16, weight: .medium))
                .symbolEffect(.variableColor.iterative, isActive: dictation.isRecording)
                .foregroundStyle(dictation.isRecording ? Color.red : .secondary)
                .frame(width: 32, height: 32)
                .background(dictation.isRecording ? Color.red.opacity(0.12) : .clear, in: .circle)
        }
        .disabled(store.emergencyActive)
        .accessibilityLabel(dictation.isRecording ? "Arrêter la dictée" : "Dicter")
    }

    @ViewBuilder
    private var sendButton: some View {
        if store.isStreaming {
            Button("Arrêter", systemImage: "stop.fill") { store.stop() }
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(.systemBackground))
                .frame(width: 32, height: 32)
                .background(.primary, in: .circle)
        } else if store.draft.isEmpty, store.pendingAttachments.isEmpty, !store.isPreparingAttachment, !store.emergencyActive {
            // Nothing to send: talk instead, like Grok's voice mode.
            Button("Mode vocal", systemImage: "waveform") {
                if dictation.isRecording { dictation.stop() }
                showVoiceMode = true
            }
            .labelStyle(.iconOnly)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(Color(.systemBackground))
            .frame(width: 32, height: 32)
            .background(.primary, in: .circle)
        } else {
            Button("Envoyer", systemImage: "arrow.up") {
                if dictation.isRecording { dictation.stop() }
                store.send()
            }
            .labelStyle(.iconOnly)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(store.canSend ? Color.accentColor : Color.secondary.opacity(0.35), in: .circle)
            .disabled(!store.canSend)
        }
    }
}
