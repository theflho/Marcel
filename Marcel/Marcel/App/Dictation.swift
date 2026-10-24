import AVFoundation
import Observation
import Speech

/// Dictation into the composer, transcribed on the iPhone only: no audio leaves the device.
/// When on-device recognition isn't available for French, dictation is refused rather than
/// falling back to Apple's servers.
@Observable
final class Dictation {
    private(set) var isRecording = false
    private(set) var error: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "fr-FR"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Starts listening; `update` receives the whole transcript so far each time it changes.
    func start(update: @escaping @MainActor (String) -> Void) async {
        guard !isRecording else { return }
        error = nil
        guard await Self.authorize() else {
            error = "Autorise le micro et la reconnaissance vocale dans Réglages › Marcel."
            return
        }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            error = "La dictée sur l'iPhone n'est pas disponible en français sur cet appareil."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            request.addsPunctuation = true
            Self.installTap(on: engine.inputNode, feeding: request)
            engine.prepare()
            try engine.start()

            self.request = request
            task = Self.recognize(request, with: recognizer) { [weak self] text, isFinal in
                update(text)
                if isFinal { self?.stop() }
            }
            isRecording = true
        } catch {
            self.error = "Micro indisponible : \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task?.finish()
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // The audio tap and the recognition callback run on background threads, so they are
    // set up outside the main actor.

    private nonisolated static func installTap(on input: AVAudioInputNode, feeding request: SFSpeechAudioBufferRecognitionRequest) {
        nonisolated(unsafe) let request = request
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    private nonisolated static func recognize(
        _ request: SFSpeechAudioBufferRecognitionRequest,
        with recognizer: SFSpeechRecognizer,
        onResult: @escaping @MainActor (String, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false || error != nil
            Task { @MainActor in
                if let text { onResult(text, isFinal) } else if isFinal { onResult("", true) }
            }
        }
    }

    private static func authorize() async -> Bool {
        guard await speechAuthorized() else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// iOS answers on a background thread: the callback must not belong to the main actor
    /// (Swift 6 would stop the app there).
    private nonisolated static func speechAuthorized() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }
}
