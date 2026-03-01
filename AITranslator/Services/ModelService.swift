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
            print("Failed to fetch models: \(error)")
            return []
        }
    }
}
