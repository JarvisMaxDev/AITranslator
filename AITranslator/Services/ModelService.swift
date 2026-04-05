import Foundation

/// Service to fetch available models from provider APIs
final class ModelService {
    nonisolated(unsafe) static let shared = ModelService()

    /// Fetch available Claude models from Anthropic API
    /// Requires OAuth token with anthropic-beta header
    /// Auto-refreshes token on 401 and retries once
    func fetchAnthropicModels(token: String, providerId: String? = nil) async -> [(id: String, name: String)] {
        let result = await doFetchAnthropicModels(token: token)
        if !result.isEmpty { return result }

        // If failed and we have a provider ID, try refreshing the token
        if let providerId = providerId {
            do {
                AppLogger.info("Models", "Anthropic token may be expired, refreshing...")
                let newTokens = try await OAuthService.shared.refreshClaudeToken(forProvider: providerId)
                AppLogger.success("Models", "Anthropic token refreshed, retrying models fetch")
                return await doFetchAnthropicModels(token: newTokens.accessToken)
            } catch {
                AppLogger.error("Models", "Anthropic token refresh failed", details: error.localizedDescription)
            }
        }

        return []
    }

    private func doFetchAnthropicModels(token: String) async -> [(id: String, name: String)] {
        guard let url = URL(string: "https://api.anthropic.com/v1/models") else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return [] }

            guard httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                AppLogger.error("Models", "Anthropic API returned \(httpResponse.statusCode)", details: body)
                return []
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["data"] as? [[String: Any]] else {
                let body = String(data: data, encoding: .utf8) ?? ""
                AppLogger.error("Models", "Anthropic models: unexpected response format", details: body)
                return []
            }

            return models.compactMap { model in
                guard let id = model["id"] as? String,
                      let name = model["display_name"] as? String else { return nil }
                return (id: id, name: name)
            }
        } catch {
            AppLogger.error("Models", "Failed to fetch Anthropic models", details: error.localizedDescription)
            return []
        }
    }

    /// Fetch available OpenAI models.
    /// - OAuth token → Codex backend (chatgpt.com/backend-api/codex/models)
    /// - API key → standard platform API (api.openai.com/v1/models)
    func fetchOpenAIModels(token: String?, apiKey: String?, baseURL: String = "https://api.openai.com/v1") async -> [(id: String, name: String)] {
        if let token = token {
            return await fetchCodexModels(token: token)
        } else if let apiKey = apiKey {
            return await fetchPlatformModels(apiKey: apiKey, baseURL: baseURL)
        }
        return []
    }

    // MARK: - Codex models (OAuth via ChatGPT subscription)

    /// Fetch models from Codex backend — same endpoint as Codex CLI
    /// GET https://chatgpt.com/backend-api/codex/models?client_version=0.1.0
    /// Response: { "models": [{ "slug": "gpt-5.2-codex", "display_name": "...", "description": "..." }] }
    private func fetchCodexModels(token: String) async -> [(id: String, name: String)] {
        guard let url = URL(string: "https://chatgpt.com/backend-api/codex/models?client_version=0.1.0") else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else {
                let errorBody = String(data: data, encoding: .utf8) ?? ""
                AppLogger.error("Models", "Failed to fetch Codex models", details: errorBody)
                return []
            }

            return models.compactMap { model in
                guard let slug = model["slug"] as? String else { return nil }
                let displayName = model["display_name"] as? String ?? slug
                return (id: slug, name: displayName)
            }
        } catch {
            AppLogger.error("Models", "Failed to fetch Codex models", details: error.localizedDescription)
            return []
        }
    }

    // MARK: - Platform models (API key)

    /// Fetch models from standard OpenAI platform API
    /// GET https://api.openai.com/v1/models
    private func fetchPlatformModels(apiKey: String, baseURL: String) async -> [(id: String, name: String)] {
        guard let url = URL(string: "\(baseURL)/models") else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["data"] as? [[String: Any]] else {
                let errorBody = String(data: data, encoding: .utf8) ?? ""
                AppLogger.error("Models", "Failed to fetch OpenAI platform models", details: errorBody)
                return []
            }

            // Filter to chat-capable models
            let chatModels = models.compactMap { model -> (id: String, name: String)? in
                guard let id = model["id"] as? String else { return nil }

                let validPrefixes = ["gpt-", "o1", "o3", "o4", "chatgpt-"]
                guard validPrefixes.contains(where: { id.hasPrefix($0) }) else { return nil }

                if id.contains("realtime") || id.contains("audio") || id.contains("tts")
                    || id.contains("whisper") || id.contains("embedding")
                    || id.contains("dall-e") || id.contains("moderation") { return nil }

                return (id: id, name: id)
            }

            return chatModels.sorted { $0.id > $1.id }
        } catch {
            AppLogger.error("Models", "Failed to fetch OpenAI platform models", details: error.localizedDescription)
            return []
        }
    }

    // MARK: - Gemini models

    /// Fetch available Gemini models via Google AI API
    func fetchGeminiModels(token: String, providerId: String? = nil) async -> [(id: String, name: String)] {
        let result = await doFetchGeminiModels(token: token)
        if !result.isEmpty { return result }

        if let providerId = providerId {
            do {
                AppLogger.info("Models", "Gemini token may be expired, refreshing...")
                let newTokens = try await OAuthService.shared.refreshGeminiToken(forProvider: providerId)
                AppLogger.success("Models", "Gemini token refreshed, retrying models fetch")
                return await doFetchGeminiModels(token: newTokens.accessToken)
            } catch {
                AppLogger.error("Models", "Gemini token refresh failed", details: error.localizedDescription)
            }
        }
        return []
    }

    /// Google does not expose a models list API for cloudcode-pa.
    /// gemini-cli also hardcodes models. Return known models.
    private func doFetchGeminiModels(token: String) async -> [(id: String, name: String)] {
        return [
            (id: "gemini-3.1-pro-preview", name: "Gemini 3.1 Pro Preview"),
            (id: "gemini-3-flash-preview", name: "Gemini 3 Flash Preview"),
            (id: "gemini-2.5-pro", name: "Gemini 2.5 Pro"),
            (id: "gemini-2.5-flash", name: "Gemini 2.5 Flash"),
            (id: "gemini-2.5-flash-lite", name: "Gemini 2.5 Flash Lite"),
        ]
    }

    // MARK: - Qwen models

    /// Fetch available Qwen models via Qwen API
    func fetchQwenModels(token: String, providerId: String? = nil) async -> [(id: String, name: String)] {
        let result = await doFetchQwenModels(token: token)
        if !result.isEmpty { return result }

        if let providerId = providerId {
            do {
                AppLogger.info("Models", "Qwen token may be expired, refreshing...")
                let newTokens = try await OAuthService.shared.refreshQwenToken(forProvider: providerId)
                AppLogger.success("Models", "Qwen token refreshed, retrying models fetch")
                return await doFetchQwenModels(token: newTokens.accessToken)
            } catch {
                AppLogger.error("Models", "Qwen token refresh failed", details: error.localizedDescription)
            }
        }
        return []
    }

    private func doFetchQwenModels(token: String) async -> [(id: String, name: String)] {
        guard let url = URL(string: "https://chat.qwen.ai/api/models") else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                AppLogger.error("Models", "Qwen models API error", details: body)
                return []
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else {
                // Try alternative response format: {"data": [...]}
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let models = json["data"] as? [[String: Any]] else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    AppLogger.error("Models", "Qwen models: unexpected format", details: body)
                    return []
                }
                return models.compactMap { model in
                    guard let id = model["id"] as? String else { return nil }
                    let name = model["name"] as? String ?? id
                    return (id: id, name: name)
                }
            }

            return models.compactMap { model in
                guard let slug = model["slug"] as? String ?? model["id"] as? String else { return nil }
                let displayName = model["display_name"] as? String ?? model["name"] as? String ?? slug
                return (id: slug, name: displayName)
            }
        } catch {
            AppLogger.error("Models", "Failed to fetch Qwen models", details: error.localizedDescription)
            return []
        }
    }
}
