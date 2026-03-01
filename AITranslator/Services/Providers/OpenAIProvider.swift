import Foundation

/// OpenAI provider supporting two auth methods:
/// - OAuth via ChatGPT subscription → uses Codex Responses API (chatgpt.com/backend-api)
/// - API key → uses standard Chat Completions API (api.openai.com/v1)
final class OpenAIProvider: AIProvider {
    let id: String
    let type: ProviderType = .openai
    private let config: ProviderConfig
    private let keychain = KeychainService.shared

    /// Codex Responses API endpoint (used with OAuth / ChatGPT subscription)
    private let codexBaseURL = "https://chatgpt.com/backend-api"

    var isAuthenticated: Bool {
        keychain.getOAuthTokens(forProvider: config.id) != nil ||
        keychain.getAPIKey(forProvider: config.id) != nil
    }

    init(config: ProviderConfig) {
        self.id = config.id
        self.config = config
    }

    func authenticate() async throws {
        // OAuth and API key auth handled via settings
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResponse {
        // Choose path based on auth method
        if let tokens = keychain.getOAuthTokens(forProvider: config.id) {
            return try await translateViaCodex(request, tokens: tokens)
        } else if let apiKey = keychain.getAPIKey(forProvider: config.id) {
            return try await translateViaAPI(request, apiKey: apiKey)
        } else {
            throw AIProviderError.notAuthenticated
        }
    }

    // MARK: - OAuth path: Codex Responses API (ChatGPT subscription)

    private func translateViaCodex(_ request: TranslationRequest, tokens: OAuthTokens) async throws -> TranslationResponse {
        var currentTokens = tokens

        // Auto-refresh if expired
        if currentTokens.isExpired {
            do {
                AppLogger.info("OpenAI", "Token expired, refreshing...")
                currentTokens = try await OAuthService.shared.refreshOpenAIToken(forProvider: config.id)
                AppLogger.success("OpenAI", "Token refreshed successfully")
            } catch {
                AppLogger.error("OpenAI", "Token refresh failed", details: String(describing: error))
                throw AIProviderError.tokenExpired
            }
        }

        let url = URL(string: "\(codexBaseURL)/codex/responses")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(currentTokens.accessToken)", forHTTPHeaderField: "Authorization")
        urlRequest.timeoutInterval = 60

        let systemPrompt = buildSystemPrompt(request: request)

        // Responses API format — input must be array of message objects
        let body: [String: Any] = [
            "model": config.model,
            "instructions": systemPrompt,
            "input": [
                ["type": "message", "role": "user", "content": request.sourceText]
            ],
            "stream": false
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        urlRequest.httpBody = bodyData

        // Log request
        if let prettyBody = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]),
           let bodyStr = String(data: prettyBody, encoding: .utf8) {
            AppLogger.request("OpenAI·OAuth", "POST \(url.absoluteString)", details: bodyStr)
        }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            AppLogger.error("OpenAI", "OAuth token expired (401)")
            throw AIProviderError.tokenExpired
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            AppLogger.error("OpenAI", "Codex API error (\(httpResponse.statusCode))", details: errorBody)
            throw AIProviderError.apiError("OpenAI Codex API error (\(httpResponse.statusCode)): \(errorBody)")
        }

        // Parse Responses API response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIProviderError.invalidResponse
        }

        // Log response
        if let prettyResponse = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
           let responseStr = String(data: prettyResponse, encoding: .utf8) {
            AppLogger.response("OpenAI·OAuth", "200 OK", details: responseStr)
        }

        // Responses API returns output in various formats, try to extract text
        let translatedText: String
        if let output = json["output"] as? [[String: Any]] {
            // Array of output items — find text content
            let texts = output.compactMap { item -> String? in
                if let content = item["content"] as? [[String: Any]] {
                    return content.compactMap { $0["text"] as? String }.joined()
                }
                if let text = item["text"] as? String { return text }
                return nil
            }
            translatedText = texts.joined(separator: "\n")
        } else if let outputText = json["output_text"] as? String {
            translatedText = outputText
        } else if let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String {
            // Fallback: standard chat completions format
            translatedText = content
        } else {
            throw AIProviderError.invalidResponse
        }

        return TranslationResponse(
            translatedText: translatedText.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedLanguage: nil
        )
    }

    // MARK: - API key path: standard Chat Completions

    private func translateViaAPI(_ request: TranslationRequest, apiKey: String) async throws -> TranslationResponse {
        let url = URL(string: "\(config.baseURL)/chat/completions")!
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

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        urlRequest.httpBody = bodyData

        // Log request
        if let prettyBody = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]),
           let bodyStr = String(data: prettyBody, encoding: .utf8) {
            AppLogger.request("OpenAI·API", "POST \(url.absoluteString)", details: bodyStr)
        }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            AppLogger.error("OpenAI", "Authentication failed (401)")
            throw AIProviderError.notAuthenticated
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            AppLogger.error("OpenAI", "API error (\(httpResponse.statusCode))", details: errorBody)
            throw AIProviderError.apiError("OpenAI API error (\(httpResponse.statusCode)): \(errorBody)")
        }

        // Parse Chat Completions response
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
            AppLogger.response("OpenAI·API", "200 OK", details: responseStr)
        }

        return TranslationResponse(
            translatedText: content.trimmingCharacters(in: .whitespacesAndNewlines),
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
