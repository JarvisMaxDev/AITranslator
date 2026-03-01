import Foundation

/// Qwen AI provider using OpenAI-compatible API
/// Supports OAuth browser login and API key auth.
/// Uses different base URLs depending on auth method:
///   - OAuth: resource_url from token response, or portal.qwen.ai/api/v1
///   - API Key: dashscope.aliyuncs.com/compatible-mode/v1
final class QwenProvider: AIProvider {
    let id: String
    let type: ProviderType = .qwen
    private let config: ProviderConfig
    private let keychain = KeychainService.shared

    var isAuthenticated: Bool {
        if let tokens = keychain.getOAuthTokens(forProvider: config.id) {
            if tokens.isExpired {
                // Token expired — but we might have a refresh token
                // For now, mark as not authenticated so user re-authenticates
                return false
            }
            return true
        }
        return keychain.getAPIKey(forProvider: config.id) != nil
    }

    init(config: ProviderConfig) {
        self.id = config.id
        self.config = config
    }

    func authenticate() async throws {
        // OAuth flow is handled externally via OAuthService
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResponse {
        let (authHeader, baseURL, modelName) = try getAuthConfig()

        let url = URL(string: "\(baseURL)/chat/completions")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(authHeader, forHTTPHeaderField: "Authorization")
        urlRequest.timeoutInterval = 60

        let systemPrompt = buildSystemPrompt(request: request)
        let body: [String: Any] = [
            "model": modelName,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": request.sourceText]
            ],
            "temperature": 0.3,
            "max_tokens": 4096,
            "enable_thinking": false  // Disable thinking/reasoning for fast translation
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
            throw AIProviderError.apiError("Qwen API error (\(httpResponse.statusCode)): \(errorBody)")
        }

        // Parse OpenAI-compatible response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIProviderError.invalidResponse
        }

        return TranslationResponse(
            translatedText: content.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedLanguage: nil
        )
    }

    // MARK: - Private

    /// Returns (authHeader, baseURL, model) based on available credentials.
    /// OAuth: resource_url normalized + "coder-model"
    /// API key: config.baseURL + config apiKeyModel
    private func getAuthConfig() throws -> (String, String, String) {
        // Try OAuth first
        if let tokens = keychain.getOAuthTokens(forProvider: config.id) {
            if tokens.isExpired {
                throw AIProviderError.tokenExpired
            }

            let baseURL = normalizeEndpoint(tokens.resourceURL)
            // OAuth uses "coder-model" (Qwen 3.5 Plus via portal.qwen.ai)
            return ("Bearer \(tokens.accessToken)", baseURL, "coder-model")
        }

        // Fall back to API key
        if let apiKey = keychain.getAPIKey(forProvider: config.id) {
            // API key uses DashScope with standard model names
            return ("Bearer \(apiKey)", config.baseURL, config.type.apiKeyModel)
        }

        throw AIProviderError.notAuthenticated
    }

    /// Normalize endpoint URL (matching qwen-code's getCurrentEndpoint logic)
    private func normalizeEndpoint(_ resourceURL: String?) -> String {
        let defaultURL = "https://dashscope.aliyuncs.com/compatible-mode/v1"
        guard let url = resourceURL, !url.isEmpty else {
            return defaultURL
        }

        var normalized = url
        if !normalized.hasPrefix("http") {
            normalized = "https://\(normalized)"
        }
        if !normalized.hasSuffix("/v1") {
            normalized = "\(normalized)/v1"
        }
        return normalized
    }

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
