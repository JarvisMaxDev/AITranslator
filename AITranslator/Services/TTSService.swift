import AVFoundation

/// Text-to-Speech service using OpenAI-compatible /v1/audio/speech endpoint
/// Works with any provider that supports this endpoint (OpenAI, Qwen, etc.)
@MainActor
final class TTSService: ObservableObject {
    @Published var isSpeaking: Bool = false

    private var audioPlayer: AVAudioPlayer?
    private var playerDelegate: PlayerDelegate?
    private var currentTask: Task<Void, Never>?

    /// Available TTS voices (OpenAI-compatible)
    static let defaultVoice = "nova"

    /// Speak text using the selected provider's TTS endpoint
    func speak(text: String, languageCode: String,
               selectedProviderId: String?,
               providerConfigs: [ProviderConfig]) {
        // Toggle: if speaking, stop
        if isSpeaking {
            stop()
            return
        }

        // Find auth credentials and base URL for TTS
        guard let ttsConfig = findTTSConfig(selectedProviderId: selectedProviderId,
                                             configs: providerConfigs) else {
            AppLogger.error("TTS", "No authenticated provider found for TTS")
            return
        }

        isSpeaking = true
        currentTask = Task {
            await synthesize(text: text, config: ttsConfig)
        }
    }

    /// Stop playback
    func stop() {
        currentTask?.cancel()
        currentTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        playerDelegate = nil
        isSpeaking = false
    }

    // MARK: - Provider Resolution

    private struct TTSConfig {
        let authHeader: String
        let baseURL: String
    }

    /// Find the best available TTS config from provider configs
    private func findTTSConfig(selectedProviderId: String?,
                                configs: [ProviderConfig]) -> TTSConfig? {
        let keychain = KeychainService.shared

        // Order: selected provider first, then any authenticated provider
        var orderedConfigs = configs
        if let selectedId = selectedProviderId,
           let idx = orderedConfigs.firstIndex(where: { $0.id == selectedId }) {
            let selected = orderedConfigs.remove(at: idx)
            orderedConfigs.insert(selected, at: 0)
        }

        for config in orderedConfigs {
            // Try OAuth tokens first
            if let tokens = keychain.getOAuthTokens(forProvider: config.id) {
                let baseURL = resolveBaseURL(tokens: tokens, config: config)
                AppLogger.info("TTS", "Using \(config.type.displayName) OAuth for TTS (base: \(baseURL))")
                return TTSConfig(authHeader: "Bearer \(tokens.accessToken)",
                                baseURL: baseURL)
            }

            // Try API key
            if let apiKey = keychain.getAPIKey(forProvider: config.id) {
                let baseURL = resolveBaseURLForAPIKey(config: config)
                AppLogger.info("TTS", "Using \(config.type.displayName) API key for TTS (base: \(baseURL))")
                return TTSConfig(authHeader: "Bearer \(apiKey)",
                                baseURL: baseURL)
            }
        }

        return nil
    }

    /// Resolve base URL for OAuth-authenticated provider
    private func resolveBaseURL(tokens: OAuthTokens, config: ProviderConfig) -> String {
        // Use the same base URL the provider uses for translation
        switch config.type {
        case .qwen:
            // Qwen OAuth uses resourceURL or portal.qwen.ai
            if let resourceURL = tokens.resourceURL, !resourceURL.isEmpty {
                var url = resourceURL
                // Ensure it ends with /v1
                if !url.hasSuffix("/v1") {
                    url = url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    url += "/v1"
                }
                return url
            }
            return "https://portal.qwen.ai/v1"
        case .openai:
            return "https://api.openai.com/v1"
        case .anthropic:
            // Anthropic doesn't support TTS
            return ""
        case .gemini:
            return "https://generativelanguage.googleapis.com/v1beta/openai"
        }
    }

    /// Resolve base URL for API key provider
    private func resolveBaseURLForAPIKey(config: ProviderConfig) -> String {
        if !config.baseURL.isEmpty {
            return config.baseURL
        }
        switch config.type {
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .openai: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .anthropic: return ""
        }
    }

    // MARK: - Synthesis

    private func synthesize(text: String, config: TTSConfig) async {
        guard !config.baseURL.isEmpty else {
            AppLogger.error("TTS", "Provider does not support TTS")
            isSpeaking = false
            return
        }

        let ttsURL = "\(config.baseURL)/audio/speech"
        guard let url = URL(string: ttsURL) else {
            AppLogger.error("TTS", "Invalid TTS URL: \(ttsURL)")
            isSpeaking = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.authHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        // Truncate to TTS limit (4096 chars)
        let truncated = String(text.prefix(4096))

        let body: [String: Any] = [
            "model": "tts-1",
            "input": truncated,
            "voice": TTSService.defaultVoice,
            "response_format": "mp3"
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        AppLogger.info("TTS", "POST \(ttsURL) voice=\(TTSService.defaultVoice)")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard !Task.isCancelled else { return }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(domain: "TTS", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
            }

            if httpResponse.statusCode != 200 {
                let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
                AppLogger.error("TTS", "TTS error (\(httpResponse.statusCode))", details: errorText)
                isSpeaking = false
                return
            }

            guard !Task.isCancelled else { return }

            // Play audio
            let player = try AVAudioPlayer(data: data)
            let delegate = PlayerDelegate { [weak self] in
                Task { @MainActor [weak self] in
                    self?.isSpeaking = false
                    self?.audioPlayer = nil
                    self?.playerDelegate = nil
                }
            }
            player.delegate = delegate
            self.audioPlayer = player
            self.playerDelegate = delegate
            player.play()

            AppLogger.success("TTS", "Playing \(data.count) bytes of audio")
        } catch {
            if !Task.isCancelled {
                AppLogger.error("TTS", "TTS failed", details: error.localizedDescription)
                isSpeaking = false
            }
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
