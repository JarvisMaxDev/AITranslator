import AVFoundation

/// Text-to-Speech service using OpenAI TTS API
/// Falls back to system AVSpeechSynthesizer if no API key available
@MainActor
final class TTSService: ObservableObject {
    @Published var isSpeaking: Bool = false

    private var audioPlayer: AVAudioPlayer?
    private var currentTask: Task<Void, Never>?

    /// Available OpenAI TTS voices
    static let voices = ["alloy", "echo", "fable", "onyx", "nova", "shimmer"]
    static let defaultVoice = "nova"

    /// Speak text using OpenAI TTS API
    func speak(text: String, languageCode: String, providerConfigs: [ProviderConfig]? = nil) {
        // Toggle: if speaking, stop
        if isSpeaking {
            stop()
            return
        }

        // Try to find OpenAI API key
        let keychain = KeychainService.shared
        var apiKey: String?

        // Look for any OpenAI provider with API key
        if let configs = providerConfigs {
            for config in configs where config.type == .openai {
                if let key = keychain.getAPIKey(forProvider: config.id) {
                    apiKey = key
                    break
                }
            }
        }

        guard let key = apiKey else {
            AppLogger.error("TTS", "No OpenAI API key found, TTS unavailable")
            // Fall back to system TTS
            speakWithSystem(text: text, languageCode: languageCode)
            return
        }

        isSpeaking = true
        currentTask = Task {
            await synthesizeWithOpenAI(text: text, apiKey: key)
        }
    }

    /// Stop playback
    func stop() {
        currentTask?.cancel()
        currentTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isSpeaking = false
    }

    // MARK: - OpenAI TTS

    private func synthesizeWithOpenAI(text: String, apiKey: String) async {
        let url = URL(string: "https://api.openai.com/v1/audio/speech")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Truncate to TTS limit (4096 chars)
        let truncated = String(text.prefix(4096))

        let body: [String: Any] = [
            "model": "tts-1",
            "input": truncated,
            "voice": TTSService.defaultVoice,
            "response_format": "mp3"
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        AppLogger.info("TTS", "OpenAI TTS: \(truncated.prefix(50))... voice=\(TTSService.defaultVoice)")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard !Task.isCancelled else { return }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(domain: "TTS", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
            }

            guard httpResponse.statusCode == 200 else {
                let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
                AppLogger.error("TTS", "API error \(httpResponse.statusCode)", details: errorText)
                // Fall back to system TTS on API error
                speakWithSystem(text: String(text.prefix(500)), languageCode: "en")
                return
            }

            guard !Task.isCancelled else { return }

            // Play audio
            let player = try AVAudioPlayer(data: data)
            self.audioPlayer = player
            player.delegate = PlayerDelegate { [weak self] in
                Task { @MainActor [weak self] in
                    self?.isSpeaking = false
                    self?.audioPlayer = nil
                }
            }
            player.play()

            AppLogger.success("TTS", "Playing \(data.count) bytes of audio")
        } catch {
            if !Task.isCancelled {
                AppLogger.error("TTS", "TTS failed", details: error.localizedDescription)
                isSpeaking = false
            }
        }
    }

    // MARK: - System TTS Fallback

    private var systemSynthesizer: AVSpeechSynthesizer?

    private func speakWithSystem(text: String, languageCode: String) {
        let synth = AVSpeechSynthesizer()
        systemSynthesizer = synth

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        let voiceLanguage = mapLanguageCode(languageCode)
        if let voice = AVSpeechSynthesisVoice(language: voiceLanguage) {
            utterance.voice = voice
        }

        isSpeaking = true
        synth.speak(utterance)
    }

    private func mapLanguageCode(_ code: String) -> String {
        switch code {
        case "zh": return "zh-CN"
        case "pt": return "pt-BR"
        case "en": return "en-US"
        default: return code
        }
    }
}

// MARK: - Audio Player Delegate

private class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    private let onFinish: @Sendable () -> Void

    init(onFinish: @escaping @Sendable () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }
}
