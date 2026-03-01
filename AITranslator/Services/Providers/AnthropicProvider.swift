import Foundation

/// Anthropic Claude provider using Messages API
/// Supports OAuth browser login and API key auth
final class AnthropicProvider: AIProvider {
    let id: String
    let type: ProviderType = .anthropic
    private let config: ProviderConfig
    private let keychain = KeychainService.shared

    var isAuthenticated: Bool {
        if let tokens = keychain.getOAuthTokens(forProvider: config.id) {
            return !tokens.isExpired
        }
        return keychain.getAPIKey(forProvider: config.id) != nil
    }

    init(config: ProviderConfig) {
        self.id = config.id
        self.config = config
    }

    func authenticate() async throws {
        // OAuth flow is handled externally
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResponse {
        let url = URL(string: "\(config.baseURL)/messages")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.timeoutInterval = 30

        // Set auth header based on method
        if let tokens = keychain.getOAuthTokens(forProvider: config.id) {
            urlRequest.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
            // OAuth requires beta header to enable OAuth token support in Messages API
            urlRequest.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        } else if let apiKey = keychain.getAPIKey(forProvider: config.id) {
            urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        } else {
            throw AIProviderError.notAuthenticated
        }

        let systemPrompt = buildSystemPrompt(request: request)
        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": request.sourceText]
            ]
        ]

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw AIProviderError.tokenExpired
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIProviderError.apiError("Anthropic API error (\(httpResponse.statusCode)): \(errorBody)")
        }

        // Parse Anthropic Messages API response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw AIProviderError.invalidResponse
        }

        return TranslationResponse(
            translatedText: text.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedLanguage: nil
        )
    }

    // MARK: - Private

    private func buildSystemPrompt(request: TranslationRequest) -> String {
        let sourceLang = request.sourceLanguage.code == "auto"
            ? "auto-detected language"
            : request.sourceLanguage.name
        let targetLang = request.targetLanguage.name

        return """
        You are a professional translator. Translate the following text from \(sourceLang) to \(targetLang).
        
        Rules:
        - Return ONLY the translated text, nothing else
        - Preserve the original formatting (line breaks, paragraphs)
        - Maintain the tone and style of the original text
        - Do not add explanations, notes, or comments
        - If the text is already in the target language, return it as-is
        """
    }
}
