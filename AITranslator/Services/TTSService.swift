import AVFoundation

/// Text-to-Speech service using AVSpeechSynthesizer
@MainActor
final class TTSService: NSObject, ObservableObject {
    @Published var isSpeaking: Bool = false

    private let synthesizer = AVSpeechSynthesizer()
    private var delegate: TTSDelegate?

    override init() {
        super.init()
        delegate = TTSDelegate { [weak self] in
            self?.isSpeaking = false
        }
        synthesizer.delegate = delegate
    }

    /// Speak text in the given language
    func speak(text: String, languageCode: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            isSpeaking = false
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
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// Stop speaking
    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
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

// MARK: - Delegate (non-MainActor)

private class TTSDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private let onFinish: @Sendable () -> Void

    init(onFinish: @escaping @Sendable () -> Void) {
        self.onFinish = onFinish
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.onFinish()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.onFinish()
        }
    }
}
