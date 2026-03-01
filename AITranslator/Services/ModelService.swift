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

    /// Fetch available OpenAI models via /v1/models API
    /// Works with both OAuth token and API key
    func fetchOpenAIModels(token: String?, apiKey: String?, baseURL: String = "https://api.openai.com/v1") async -> [(id: String, name: String)] {
        guard let url = URL(string: "\(baseURL)/models") else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if let apiKey = apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        } else {
            return []
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["data"] as? [[String: Any]] else {
                let errorBody = String(data: data ?? Data(), encoding: .utf8) ?? ""
                AppLogger.error("Models", "Failed to fetch OpenAI models", details: errorBody)
                return []
            }

            // Filter to chat-capable models and format names
            let chatModels = models.compactMap { model -> (id: String, name: String)? in
                guard let id = model["id"] as? String else { return nil }

                // Only include models likely usable for chat/translation
                let validPrefixes = ["gpt-", "o1", "o3", "o4", "chatgpt-"]
                guard validPrefixes.contains(where: { id.hasPrefix($0) }) else { return nil }

                // Skip internal/special models
                if id.contains("realtime") || id.contains("audio") || id.contains("tts")
                    || id.contains("whisper") || id.contains("embedding")
                    || id.contains("dall-e") || id.contains("moderation") { return nil }

                let displayName = formatOpenAIModelName(id)
                return (id: id, name: displayName)
            }

            // Sort: newer/bigger models first
            return chatModels.sorted { a, b in
                a.id > b.id
            }
        } catch {
            AppLogger.error("Models", "Failed to fetch OpenAI models", details: error.localizedDescription)
            return []
        }
    }

    // MARK: - Private

    /// Format OpenAI model ID into a readable name
    /// e.g. "gpt-4o-2025-03-01" → "GPT-4o (2025-03-01)"
    /// e.g. "gpt-4.1-mini" → "GPT-4.1 Mini"
    private func formatOpenAIModelName(_ id: String) -> String {
        var name = id

        // Capitalize GPT prefix
        if name.hasPrefix("gpt-") {
            name = "GPT-" + name.dropFirst(4)
        } else if name.hasPrefix("chatgpt-") {
            name = "ChatGPT-" + name.dropFirst(8)
        } else if name.hasPrefix("o1") || name.hasPrefix("o3") || name.hasPrefix("o4") {
            // Keep o1/o3/o4 as-is but capitalize suffixes
            let parts = name.split(separator: "-", maxSplits: 1)
            if parts.count > 1 {
                name = String(parts[0]) + "-" + parts[1].capitalized
            }
        }

        // Extract date suffix like -2025-03-01
        let datePattern = #"-(\d{4}-\d{2}-\d{2})$"#
        if let range = name.range(of: datePattern, options: .regularExpression) {
            let date = String(name[range]).dropFirst() // remove leading "-"
            name = String(name[name.startIndex..<range.lowerBound]) + " (\(date))"
        }

        // Capitalize common suffixes
        name = name.replacingOccurrences(of: "-mini", with: " Mini")
        name = name.replacingOccurrences(of: "-nano", with: " Nano")
        name = name.replacingOccurrences(of: "-preview", with: " Preview")
        name = name.replacingOccurrences(of: "-latest", with: " Latest")

        return name
    }
}

