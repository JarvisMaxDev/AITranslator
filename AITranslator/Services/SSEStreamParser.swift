import Foundation

/// Shared SSE (Server-Sent Events) stream parser for AI providers.
/// Handles both OpenAI-compatible and Anthropic stream formats.
enum SSEStreamParser {

    // MARK: - OpenAI-compatible format (OpenAI, Qwen, Gemini)

    /// Parse a single SSE line and extract the text delta.
    /// Format: `data: {"choices":[{"delta":{"content":"text"}}]}`
    /// Returns nil for non-data lines, empty deltas, or [DONE].
    static func parseOpenAIDelta(_ line: String) -> String? {
        guard line.hasPrefix("data: ") else { return nil }
        let jsonStr = String(line.dropFirst(6))
        if jsonStr == "[DONE]" { return nil }

        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let delta = firstChoice["delta"] as? [String: Any],
              let content = delta["content"] as? String,
              !content.isEmpty else {
            return nil
        }
        return content
    }

    // MARK: - Anthropic format

    /// Parse a single SSE line from the Anthropic Messages API stream.
    /// Format: `data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"..."}}`
    /// Returns nil for non-delta events.
    static func parseAnthropicDelta(_ line: String) -> String? {
        guard line.hasPrefix("data: ") else { return nil }
        let jsonStr = String(line.dropFirst(6))

        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }

        switch type {
        case "content_block_delta":
            guard let delta = json["delta"] as? [String: Any],
                  let text = delta["text"] as? String,
                  !text.isEmpty else { return nil }
            return text
        case "error":
            // Extract error message if present
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                AppLogger.error("SSE", "Stream error", details: message)
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: - OpenAI Codex Responses API format

    /// Parse SSE from OpenAI Codex Responses API (chatgpt.com/backend-api).
    /// Format: `data: {"type":"response.output_text.delta","delta":"text"}`
    static func parseCodexDelta(_ line: String) -> String? {
        guard line.hasPrefix("data: ") else { return nil }
        let jsonStr = String(line.dropFirst(6))
        if jsonStr == "[DONE]" { return nil }

        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }

        switch type {
        case "response.output_text.delta":
            return json["delta"] as? String
        case "response.failed", "error":
            if let errorMsg = (json["error"] as? [String: Any])?["message"] as? String {
                AppLogger.error("SSE", "Codex stream error", details: errorMsg)
            }
            return nil
        default:
            return nil
        }
    }
}
