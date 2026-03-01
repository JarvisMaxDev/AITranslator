import Foundation

/// Supported AI provider types
enum ProviderType: String, Codable, CaseIterable, Identifiable {
    case qwen = "qwen"
    case anthropic = "anthropic"
    case openai = "openai"
    case gemini = "gemini"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .qwen: return "Qwen"
        case .anthropic: return "Claude (Anthropic)"
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        }
    }

    var iconSystemName: String {
        switch self {
        case .qwen: return "sparkles"
        case .anthropic: return "brain.head.profile"
        case .openai: return "bolt.fill"
        case .gemini: return "diamond.fill"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openai: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        }
    }

    /// Base URL used when authenticated via OAuth (may differ from API key URL)
    var oauthBaseURL: String {
        switch self {
        case .qwen: return "https://portal.qwen.ai/api/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openai: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        }
    }

    var defaultModel: String {
        switch self {
        case .qwen: return "coder-model"
        case .anthropic: return "claude-sonnet-4-20250514"
        case .openai: return "gpt-4o"
        case .gemini: return "gemini-2.5-flash"
        }
    }

    /// Model to use with API key auth (DashScope)
    var apiKeyModel: String {
        switch self {
        case .qwen: return "qwen-plus"
        case .anthropic: return "claude-sonnet-4-20250514"
        case .openai: return "gpt-4o"
        case .gemini: return "gemini-2.5-flash"
        }
    }

    var supportsOAuth: Bool {
        switch self {
        case .qwen: return true
        case .anthropic: return true
        case .openai: return true
        case .gemini: return false
        }
    }

    /// Available models for selection (id, displayName)
    var availableModels: [(id: String, name: String)] {
        switch self {
        case .qwen:
            return [
                ("coder-model", "Qwen Coder (OAuth)"),
                ("qwen-plus", "Qwen Plus"),
                ("qwen-turbo", "Qwen Turbo"),
                ("qwen-max", "Qwen Max"),
            ]
        case .anthropic:
            return [
                ("claude-sonnet-4-20250514", "Sonnet 4"),
                ("claude-haiku-4-5-20251001", "Haiku 4.5 · Fast"),
                ("claude-sonnet-4-5-20250929", "Sonnet 4.5 · Balanced"),
                ("claude-4-opus-20250514", "Opus 4"),
                ("claude-opus-4-5-20251101", "Opus 4.5 · Best"),
            ]
        case .openai:
            return [
                ("gpt-4o", "GPT-4o"),
                ("gpt-4o-mini", "GPT-4o Mini · Fast"),
                ("gpt-4.1", "GPT-4.1"),
                ("gpt-4.1-mini", "GPT-4.1 Mini"),
                ("gpt-4.1-nano", "GPT-4.1 Nano · Cheapest"),
                ("o4-mini", "o4 Mini · Reasoning"),
            ]
        case .gemini:
            return [
                ("gemini-2.5-flash", "Gemini 2.5 Flash"),
                ("gemini-2.5-pro", "Gemini 2.5 Pro"),
                ("gemini-2.0-flash", "Gemini 2.0 Flash"),
                ("gemini-2.0-flash-lite", "Gemini 2.0 Flash-Lite · Fast"),
            ]
        }
    }
}

/// Configuration for an AI provider instance
struct ProviderConfig: Codable, Identifiable, Equatable {
    var id: String
    var type: ProviderType
    var name: String
    var baseURL: String
    var model: String
    var isEnabled: Bool
    var isAuthenticated: Bool
    var authMethod: AuthMethod

    enum AuthMethod: String, Codable {
        case oauth = "oauth"
        case apiKey = "apiKey"
    }

    init(type: ProviderType) {
        self.id = UUID().uuidString
        self.type = type
        self.name = type.displayName
        self.baseURL = type.defaultBaseURL
        self.model = type.defaultModel
        self.isEnabled = true
        self.isAuthenticated = false
        self.authMethod = type.supportsOAuth ? .oauth : .apiKey
    }
}
