import Foundation

/// Google Gemini provider using OpenAI-compatible API
/// API key auth only, via Google AI Studio
/// Uses the OpenAI compatibility layer: generativelanguage.googleapis.com/v1beta/openai
final class GeminiProvider: AIProvider {
    let id: String
    let type: ProviderType = .gemini
    private let config: ProviderConfig
    private let keychain = KeychainService.shared

    var isAuthenticated: Bool {
        keychain.getAPIKey(forProvider: config.id) != nil
    }

    init(config: ProviderConfig) {
        self.id = config.id
        self.config = config
    }

    func authenticate() async throws {
        // API key auth is handled via settings
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResponse {
        guard let apiKey = keychain.getAPIKey(forProvider: config.id) else {
            throw AIProviderError.notAuthenticated
        }

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
            AppLogger.request("Gemini", "POST \(url.absoluteString)", details: bodyStr)
        }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            AppLogger.error("Gemini", "Authentication failed (\(httpResponse.statusCode))")
            throw AIProviderError.notAuthenticated
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            AppLogger.error("Gemini", "API error (\(httpResponse.statusCode))", details: errorBody)
            throw AIProviderError.apiError("Gemini API error (\(httpResponse.statusCode)): \(errorBody)")
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
            AppLogger.response("Gemini", "200 OK", details: responseStr)
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
