import AVFoundation

/// Text-to-Speech service using best available system voices
/// Automatically selects Premium > Enhanced > Default quality voice for the language
@MainActor
final class TTSService: ObservableObject {
    @Published var isSpeaking: Bool = false

    private var synthesizer: AVSpeechSynthesizer?
    private var delegate: SpeechDelegate?

    /// Speak text using the best available system voice for the language
    func speak(text: String, languageCode: String,
               selectedProviderId: String? = nil,
               providerConfigs: [ProviderConfig] = []) {
        // Toggle: if speaking, stop
        if isSpeaking {
            stop()
            return
        }

        let synth = AVSpeechSynthesizer()
        let del = SpeechDelegate { [weak self] in
            Task { @MainActor [weak self] in
                self?.isSpeaking = false
                self?.synthesizer = nil
                self?.delegate = nil
            }
        }
        synth.delegate = del
        self.synthesizer = synth
        self.delegate = del

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95 // Slightly slower for clarity
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.prefersAssistiveTechnologySettings = false

        // Select the best available voice for this language
        let voiceLanguage = mapLanguageCode(languageCode)
        let bestVoice = findBestVoice(for: voiceLanguage)
        utterance.voice = bestVoice

        let voiceName = bestVoice?.name ?? "default"
        let quality = bestVoice.map { describeQuality($0.quality) } ?? "unknown"
        AppLogger.info("TTS", "Speaking in \(voiceLanguage) with voice '\(voiceName)' (\(quality))")

        isSpeaking = true
        synth.speak(utterance)
    }

    /// Stop playback
    func stop() {
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
        delegate = nil
        isSpeaking = false
    }

    // MARK: - Voice Selection

    /// Find the best available voice for a given language code
    /// Prefers: Premium > Enhanced > Default quality
    private func findBestVoice(for languageCode: String) -> AVSpeechSynthesisVoice? {
        let allVoices = AVSpeechSynthesisVoice.speechVoices()

        // Find voices matching the language
        let matchingVoices = allVoices.filter { voice in
            voice.language.lowercased().hasPrefix(languageCode.lowercased().components(separatedBy: "-").first ?? languageCode.lowercased())
        }

        if matchingVoices.isEmpty {
            // Fallback to exact language match
            return AVSpeechSynthesisVoice(language: languageCode)
        }

        // Sort by quality: premium (2) > enhanced (1) > default (0)
        let sorted = matchingVoices.sorted { $0.quality.rawValue > $1.quality.rawValue }

        let best = sorted.first
        return best
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

    /// Describe voice quality for logging
    private func describeQuality(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .default: return "default"
        case .enhanced: return "enhanced"
        case .premium: return "premium"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - Speech Delegate

private class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
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
