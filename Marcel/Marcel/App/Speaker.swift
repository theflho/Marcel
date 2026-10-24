import AVFoundation
import Observation

/// Reads Marcel's replies aloud with the iPhone's own French voice: on the device, offline,
/// nothing is sent anywhere.
@Observable
final class Speaker {
    static let autoReadKey = "readRepliesAloud"

    /// The message being read, if any.
    private(set) var speakingID: UUID?

    private let synthesizer = AVSpeechSynthesizer()
    private let delegate = SpeechDelegate()

    init() {
        synthesizer.delegate = delegate
        delegate.onFinish = { [weak self] in
            Task { @MainActor in self?.finished() }
        }
    }

    func toggle(_ message: ChatMessage) {
        if speakingID == message.id { stop() } else { speak(message) }
    }

    func speak(_ message: ChatMessage) {
        let text = Self.plainText(AssistantDraft.split(AssistantProposal.split(message.content).text).text)
        guard !text.isEmpty else { return }
        stop()
        let session = AVAudioSession.sharedInstance()
        // Plays even with the silent switch on, and lowers music instead of stopping it.
        try? session.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice
        speakingID = message.id
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        finished()
    }

    private func finished() {
        guard speakingID != nil else { return }
        speakingID = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The best French voice installed (premium or enhanced ones are downloaded in iOS Settings).
    private static var voice: AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "fr-FR" }
            .max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: "fr-FR")
    }

    /// The reply without Markdown signs, which a voice would read out ("dièse", "astérisque").
    static func plainText(_ markdown: String) -> String {
        var text = markdown
        let replacements: [(String, String)] = [
            ("```[\\s\\S]*?(```|$)", " (bloc de code) "),
            ("\\[([^\\]]+)\\]\\([^)]+\\)", "$1"),
            ("(?m)^\\s{0,3}#{1,6}\\s*", ""),
            ("(?m)^\\s*>\\s?", ""),
            ("(?m)^\\s*[-*+]\\s+", ""),
            ("(?m)^\\s*\\|?[\\s:|-]+\\|[\\s:|-]*$", ""),
            ("[*_`|]", " "),
            ("https?://\\S+", "un lien"),
            ("[ \\t]{2,}", " "),
        ]
        for (pattern, template) in replacements {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The synthesizer calls back on its own thread, outside the main actor.
private nonisolated final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var onFinish: (@Sendable () -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onFinish?()
    }
}
