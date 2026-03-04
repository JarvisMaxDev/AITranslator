import AVFoundation

/// Text-to-Speech service using AVSpeechSynthesizer
@MainActor
final class TTSService: ObservableObject {
    @Published var isSpeaking: Bool = false

    private var synthesizer: AVSpeechSynthesizer?
    private var delegate: TTSDelegate?

    /// Speak text in the given language (toggle: call again to stop)
    func speak(text: String, languageCode: String) {
        // If already speaking, stop
        if isSpeaking {
            synthesizer?.stopSpeaking(at: .immediate)
            isSpeaking = false
            synthesizer = nil
            delegate = nil
            return
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        // Map language code to BCP 47 for voice selection
        let voiceLanguage = mapLanguageCode(languageCode)
        if let voice = AVSpeechSynthesisVoice(language: voiceLanguage) {
            utterance.voice = voice
        } else {
            // Fallback: try base language
            let base = languageCode.components(separatedBy: "-").first ?? languageCode
            if let voice = AVSpeechSynthesisVoice(language: base) {
                utterance.voice = voice
            }
        }

        AppLogger.info("TTS", "Speaking in \(voiceLanguage): \(text.prefix(50))...")

        // Create fresh synthesizer and delegate for each utterance
        let synth = AVSpeechSynthesizer()
        let del = TTSDelegate(onFinish: { [weak self] in
            Task { @MainActor [weak self] in
                self?.isSpeaking = false
                self?.synthesizer = nil
                self?.delegate = nil
            }
        })
        synth.delegate = del
        self.synthesizer = synth
        self.delegate = del

        isSpeaking = true
        synth.speak(utterance)
    }

    /// Stop speaking
    func stop() {
        synthesizer?.stopSpeaking(at: .immediate)
        isSpeaking = false
        synthesizer = nil
        delegate = nil
    }

    /// Map app language codes to BCP 47 codes for TTS
    private func mapLanguageCode(_ code: String) -> String {
        switch code {
        case "zh": return "zh-CN"
        case "zh-TW": return "zh-TW"
        case "pt": return "pt-BR"
        case "pt-PT": return "pt-PT"
        case "en": return "en-US"
        default: return code
        }
    }
}

// MARK: - Delegate

private class TTSDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private let onFinish: @Sendable () -> Void

    init(onFinish: @escaping @Sendable () -> Void) {
        self.onFinish = onFinish
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        onFinish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        onFinish()
    }
}
