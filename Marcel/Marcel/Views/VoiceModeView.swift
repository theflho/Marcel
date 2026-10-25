import SwiftUI

/// Talking with Marcel hands-free, like Grok's voice mode: the iPhone listens, sends what was said
/// once the user stops talking, reads the reply aloud, then listens again. Dictation and voice stay
/// on the iPhone; only the text is sent, as a message of the open conversation.
struct VoiceModeView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private enum Phase { case listening, waiting, speaking }

    /// How long a silence ends what the user says.
    private static let silence: Duration = .seconds(1.6)

    @State private var dictation = Dictation()
    @State private var phase = Phase.listening
    @State private var transcript = ""
    @State private var lastHeard = ContinuousClock.now
    @State private var closed = false

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Spacer()
                Button("Fermer", systemImage: "xmark") { close() }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .glass(in: .circle)
                    .tint(.primary)
            }
            Spacer()
            MarcelAvatar(size: 180, mood: store.modeMood, isThinking: phase != .listening, cutout: true)
                .scaleEffect(phase == .listening && dictation.isRecording ? 1.04 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: dictation.isRecording)
            Text(status)
                .font(.title3.weight(.semibold))
                .contentTransition(.opacity)
            Text(phase == .listening ? transcript : "")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(6)
                .frame(minHeight: 80, alignment: .top)
                .padding(.horizontal, 24)
            if let error = dictation.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Button {
                phase == .speaking ? store.speaker.stop() : close()
            } label: {
                Label(phase == .speaking ? "Couper" : "Terminer", systemImage: phase == .speaking ? "stop.fill" : "phone.down.fill")
                    .font(.headline)
                    .padding(.horizontal, 28)
                    .frame(height: 54)
            }
            .buttonStyle(.borderedProminent)
            .tint(phase == .speaking ? .accentColor : .red)
            .clipShape(.capsule)
        }
        .padding()
        .background(Theme.chatBackground.ignoresSafeArea())
        .task { listen() }
        .task(id: phase) {
            // Sends what was said once the user has been quiet for a moment.
            guard phase == .listening else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                if !transcript.trimmingCharacters(in: .whitespaces).isEmpty, ContinuousClock.now - lastHeard > Self.silence {
                    send()
                    return
                }
            }
        }
        .onChange(of: store.isStreaming) { _, streaming in
            guard !streaming, phase == .waiting else { return }
            if let reply = store.conversation.messages.last, reply.role == .assistant, !reply.content.isEmpty {
                phase = .speaking
                store.speaker.speak(reply)
            } else {
                listen()
            }
        }
        .onChange(of: dictation.isRecording) { _, recording in
            // iOS ended the dictation by itself: send what was said, or listen again.
            guard !recording, phase == .listening, dictation.error == nil else { return }
            transcript.trimmingCharacters(in: .whitespaces).isEmpty ? listen() : send()
        }
        .onChange(of: store.speaker.speakingID) { _, speaking in
            if speaking == nil, phase == .speaking { listen() }
        }
        .onDisappear {
            closed = true
            dictation.stop()
            store.speaker.stop()
        }
    }

    private var status: String {
        switch phase {
        case .listening: dictation.isRecording ? "Je t'écoute…" : "Un instant…"
        case .waiting: (store.headerStatus?.text).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Réflexion…"
        case .speaking: "Marcel te répond"
        }
    }

    private func listen() {
        guard !closed, !store.emergencyActive else { return }
        transcript = ""
        lastHeard = .now
        phase = .listening
        Task {
            await dictation.start { text in
                transcript = text
                lastHeard = .now
            }
        }
    }

    private func send() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        dictation.stop()
        guard !text.isEmpty else { return listen() }
        phase = .waiting
        store.sendSuggestion(text)
    }

    private func close() {
        closed = true
        dictation.stop()
        store.speaker.stop()
        dismiss()
    }
}
