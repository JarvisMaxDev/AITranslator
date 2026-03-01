import Foundation

/// Service to fetch available models from provider APIs
final class ModelService {
    static let shared = ModelService()

    /// Fetch available Claude models from Anthropic API
    /// Requires OAuth token with anthropic-beta header
    func fetchAnthropicModels(token: String) async -> [(id: String, name: String)] {
        guard let url = URL(string: "https://api.anthropic.com/v1/models") else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["data"] as? [[String: Any]] else {
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
                let description = model["description"] as? String ?? ""
                let name = description.isEmpty ? displayName : "\(displayName) · \(description)"
                return (id: slug, name: name)
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
}
