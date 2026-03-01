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
            return true // Even if expired, refresh token may work
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
        if var tokens = keychain.getOAuthTokens(forProvider: config.id) {
            if tokens.isExpired {
                do {
                    AppLogger.info("Claude", "Token expired, refreshing...")
                    tokens = try await OAuthService.shared.refreshClaudeToken(forProvider: config.id)
                    AppLogger.success("Claude", "Token refreshed successfully")
                } catch {
                    AppLogger.error("Claude", "Token refresh failed", details: String(describing: error))
                    throw AIProviderError.tokenExpired
                }
            }
            urlRequest.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
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

        // Log pretty-printed request payload
        if let prettyBody = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]),
           let bodyStr = String(data: prettyBody, encoding: .utf8) {
            AppLogger.request("Claude", "POST \(url.absoluteString)", details: bodyStr)
        }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw AIProviderError.tokenExpired
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            AppLogger.error("Claude", "API error (\(httpResponse.statusCode))", details: errorBody)
            throw AIProviderError.apiError("Anthropic API error (\(httpResponse.statusCode)): \(errorBody)")
        }

        // Parse Anthropic Messages API response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw AIProviderError.invalidResponse
        }

        // Log        // Log response
        if let prettyResponse = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
           let responseStr = String(data: prettyResponse, encoding: .utf8) {
            AppLogger.response("Claude", "200 OK", details: responseStr)
        }
        
        let (cleanedText, detectedLang) = LanguageDetectionHelper.extractDetectedLanguage(from: text)
        
        return TranslationResponse(
            translatedText: cleanedText.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedLanguage: detectedLang
        )
    }

    // MARK: - Private

    private func buildSystemPrompt(request: TranslationRequest) -> String {
        return LanguageDetectionHelper.buildSystemPrompt(sourceLang: request.sourceLanguage.code == "auto" ? "auto" : request.sourceLanguage.name, targetLang: request.targetLanguage.name)
    }
}
