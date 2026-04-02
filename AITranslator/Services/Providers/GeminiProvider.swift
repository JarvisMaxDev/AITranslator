import Foundation

/// Google Gemini provider
/// - OAuth: cloudcode-pa.googleapis.com/v1internal (gemini-cli flow, free via Google account)
/// - API Key: generativelanguage.googleapis.com/v1beta/openai (OpenAI-compatible)
final class GeminiProvider: AIProvider {
    let id: String
    let type: ProviderType = .gemini
    private let config: ProviderConfig
    private let keychain = KeychainService.shared

    var isAuthenticated: Bool {
        if keychain.getOAuthTokens(forProvider: config.id) != nil { return true }
        return keychain.getAPIKey(forProvider: config.id) != nil
    }

    init(config: ProviderConfig) {
        self.id = config.id
        self.config = config
    }

    func authenticate() async throws {}

    func translate(_ request: TranslationRequest) async throws -> TranslationResponse {
        if let tokens = keychain.getOAuthTokens(forProvider: config.id) {
            return try await translateWithOAuth(request: request, tokens: tokens)
        } else if let apiKey = keychain.getAPIKey(forProvider: config.id) {
            return try await translateWithAPIKey(request: request, apiKey: apiKey)
        } else {
            throw AIProviderError.notAuthenticated
        }
    }

    // MARK: - OAuth path (cloudcode-pa, nativeGemini format)

    private func getFreshTokens() async throws -> OAuthTokens {
        guard var tokens = keychain.getOAuthTokens(forProvider: config.id) else {
            throw AIProviderError.notAuthenticated
        }
        if tokens.isExpired {
            do {
                AppLogger.info("Gemini", "Token expired, refreshing...")
                tokens = try await OAuthService.shared.refreshGeminiToken(forProvider: config.id)
                AppLogger.success("Gemini", "Token refreshed successfully")
            } catch {
                AppLogger.error("Gemini", "Token refresh failed", details: String(describing: error))
                keychain.deleteCredentials(forProvider: config.id)
                throw AIProviderError.tokenExpired
            }
        }
        return tokens
    }

    private func translateWithOAuth(request: TranslationRequest, tokens: OAuthTokens) async throws -> TranslationResponse {
        let freshTokens = try await getFreshTokens()
        let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:generateContent")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(freshTokens.accessToken)", forHTTPHeaderField: "Authorization")
        urlRequest.timeoutInterval = 60

        let systemPrompt = buildSystemPrompt(request: request)
        let body: [String: Any] = [
            "model": "\(config.model)",
            "contents": [["role": "user", "parts": [["text": request.sourceText]]]],
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "generationConfig": ["temperature": 0.3, "maxOutputTokens": 4096]
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        AppLogger.request("Gemini", "POST \(url.absoluteString)")

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else { throw AIProviderError.invalidResponse }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            keychain.deleteCredentials(forProvider: config.id)
            throw AIProviderError.tokenExpired
        }
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown"
            AppLogger.error("Gemini", "API error (\(httpResponse.statusCode))", details: errorBody)
            throw AIProviderError.apiError("Gemini error (\(httpResponse.statusCode)): \(errorBody)")
        }

        return try parseGeminiResponse(data: data)
    }

    private func parseGeminiResponse(data: Data) throws -> TranslationResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw AIProviderError.invalidResponse
        }
        let (cleanedText, detectedLang) = LanguageDetectionHelper.extractDetectedLanguage(from: text)
        return TranslationResponse(
            translatedText: cleanedText.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedLanguage: detectedLang
        )
    }

    // MARK: - API Key path (OpenAI-compatible)

    private func translateWithAPIKey(request: TranslationRequest, apiKey: String) async throws -> TranslationResponse {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.timeoutInterval = 60

        let systemPrompt = buildSystemPrompt(request: request)
        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": request.sourceText]
            ],
            "temperature": 0.3,
            "max_tokens": 4096
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else { throw AIProviderError.invalidResponse }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw AIProviderError.notAuthenticated
        }
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown"
            throw AIProviderError.apiError("Gemini error (\(httpResponse.statusCode)): \(errorBody)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIProviderError.invalidResponse
        }
        return TranslationResponse(
            translatedText: content.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedLanguage: nil
        )
    }

    // MARK: - Streaming

    func translateStream(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    if self.keychain.getOAuthTokens(forProvider: self.config.id) != nil {
                        try await self.streamWithOAuth(request: request, continuation: continuation)
                    } else if let apiKey = self.keychain.getAPIKey(forProvider: self.config.id) {
                        try await self.streamWithAPIKey(request: request, apiKey: apiKey, continuation: continuation)
                    } else {
                        throw AIProviderError.notAuthenticated
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func streamWithOAuth(request: TranslationRequest, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let freshTokens = try await getFreshTokens()
        let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(freshTokens.accessToken)", forHTTPHeaderField: "Authorization")
        urlRequest.timeoutInterval = 60

        let systemPrompt = buildSystemPrompt(request: request)
        let body: [String: Any] = [
            "model": "\(config.model)",
            "contents": [["role": "user", "parts": [["text": request.sourceText]]]],
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "generationConfig": ["temperature": 0.3, "maxOutputTokens": 4096]
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        AppLogger.request("Gemini", "POST stream \(url.absoluteString)")

        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else { throw AIProviderError.invalidResponse }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            keychain.deleteCredentials(forProvider: config.id)
            throw AIProviderError.tokenExpired
        }
        guard httpResponse.statusCode == 200 else {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line + "\n" }
            AppLogger.error("Gemini", "Stream error (\(httpResponse.statusCode))", details: errorBody)
            throw AIProviderError.apiError("Gemini stream error (\(httpResponse.statusCode)): \(errorBody)")
        }

        for try await line in bytes.lines {
            if let delta = SSEStreamParser.parseGeminiDelta(line) {
                continuation.yield(delta)
            }
        }
        continuation.finish()
    }

    private func streamWithAPIKey(request: TranslationRequest, apiKey: String, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.timeoutInterval = 60

        let systemPrompt = buildSystemPrompt(request: request)
        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": request.sourceText]
            ],
            "temperature": 0.3,
            "max_tokens": 4096,
            "stream": true
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        AppLogger.request("Gemini", "POST stream (API key) \(url.absoluteString)")

        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else { throw AIProviderError.invalidResponse }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 { throw AIProviderError.notAuthenticated }
        guard httpResponse.statusCode == 200 else {
            throw AIProviderError.apiError("Gemini stream error (\(httpResponse.statusCode))")
        }

        for try await line in bytes.lines {
            if let delta = SSEStreamParser.parseOpenAIDelta(line) {
                continuation.yield(delta)
            }
        }
        continuation.finish()
    }

    // MARK: - Private

    private func buildSystemPrompt(request: TranslationRequest) -> String {
        return LanguageDetectionHelper.buildSystemPrompt(
            sourceLang: request.sourceLanguage.code == "auto" ? "auto" : request.sourceLanguage.name,
            targetLang: request.targetLanguage.name
        )
    }
}
