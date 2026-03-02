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
            // Even if expired, we may have a refresh token — consider authenticated
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
        let (authHeader, baseURL, modelName) = try await getAuthConfig()

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
            "enable_thinking": false
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        urlRequest.httpBody = bodyData

        // Log pretty-printed request payload
        if let prettyBody = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]),
           let bodyStr = String(data: prettyBody, encoding: .utf8) {
            AppLogger.request("Qwen", "POST \(url.absoluteString)", details: bodyStr)
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
            AppLogger.error("Qwen", "API error (\(httpResponse.statusCode))", details: errorBody)
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

        // Log response
        if let prettyResponse = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
           let responseStr = String(data: prettyResponse, encoding: .utf8) {
            AppLogger.response("Qwen", "200 OK", details: responseStr)
        }
        
        let (cleanedText, detectedLang) = LanguageDetectionHelper.extractDetectedLanguage(from: content)

        return TranslationResponse(
            translatedText: cleanedText.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedLanguage: detectedLang
        )
    }

    // MARK: - Private

    /// Returns (authHeader, baseURL, model) based on available credentials.
    /// OAuth: resource_url normalized + "coder-model"
    /// API key: config.baseURL + config apiKeyModel
    private func getAuthConfig() async throws -> (String, String, String) {
        // Try OAuth first
        if var tokens = keychain.getOAuthTokens(forProvider: config.id) {
            if tokens.isExpired {
                // Try to refresh the token automatically
                do {
                    AppLogger.info("Qwen", "Token expired, refreshing...")
                    tokens = try await OAuthService.shared.refreshQwenToken(forProvider: config.id)
                    AppLogger.success("Qwen", "Token refreshed successfully")
                } catch {
                    AppLogger.error("Qwen", "Token refresh failed", details: String(describing: error))
                    throw AIProviderError.tokenExpired
                }
            }

            let baseURL = normalizeEndpoint(tokens.resourceURL)
            return ("Bearer \(tokens.accessToken)", baseURL, "coder-model")
        }

        // Fall back to API key
        if let apiKey = keychain.getAPIKey(forProvider: config.id) {
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
        return LanguageDetectionHelper.buildSystemPrompt(sourceLang: request.sourceLanguage.code == "auto" ? "auto" : request.sourceLanguage.name, targetLang: request.targetLanguage.name)
    }

    // MARK: - Streaming

    func translateStream(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let (authHeader, baseURL, modelName) = try await self.getAuthConfig()

                    let url = URL(string: "\(baseURL)/chat/completions")!
                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue(authHeader, forHTTPHeaderField: "Authorization")
                    urlRequest.timeoutInterval = 60

                    let systemPrompt = self.buildSystemPrompt(request: request)
                    let body: [String: Any] = [
                        "model": modelName,
                        "messages": [
                            ["role": "system", "content": systemPrompt],
                            ["role": "user", "content": request.sourceText]
                        ],
                        "temperature": 0.3,
                        "max_tokens": 4096,
                        "stream": true,
                        "enable_thinking": false
                    ]

                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
                    AppLogger.request("Qwen", "POST stream \(url.absoluteString)")

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw AIProviderError.invalidResponse
                    }
                    if httpResponse.statusCode == 401 { throw AIProviderError.tokenExpired }
                    guard httpResponse.statusCode == 200 else {
                        throw AIProviderError.apiError("Qwen stream error (\(httpResponse.statusCode))")
                    }

                    for try await line in bytes.lines {
                        if let delta = SSEStreamParser.parseOpenAIDelta(line) {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
