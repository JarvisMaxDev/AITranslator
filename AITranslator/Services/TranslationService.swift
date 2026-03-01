import Foundation

/// Main orchestrator for translation operations.
/// Delegates to the appropriate AI provider based on current configuration.
@MainActor
final class TranslationService: ObservableObject {
    @Published var isTranslating = false
    @Published var error: String?

    private var providers: [String: AIProvider] = [:]

    /// Register a provider
    func registerProvider(_ provider: AIProvider) {
        providers[provider.id] = provider
    }

    /// Create and register provider from config
    func setupProvider(from config: ProviderConfig) {
        let provider: AIProvider
        switch config.type {
        case .qwen:
            provider = QwenProvider(config: config)
        case .anthropic:
            provider = AnthropicProvider(config: config)
        }
        registerProvider(provider)
    }

    /// Translate text using the specified provider
    func translate(
        text: String,
        from sourceLanguage: Language,
        to targetLanguage: Language,
        using providerId: String
    ) async -> TranslationResponse? {
        guard let provider = providers[providerId] else {
            error = NSLocalizedString("error.provider_not_found", comment: "Provider not found")
            return nil
        }

        guard provider.isAuthenticated else {
            error = NSLocalizedString("error.not_authenticated", comment: "Provider not authenticated")
            return nil
        }

        isTranslating = true
        error = nil

        let request = TranslationRequest(
            sourceText: text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )

        do {
            let response = try await provider.translate(request)
            isTranslating = false
            return response
        } catch {
            isTranslating = false
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Check if a provider is authenticated
    func isProviderAuthenticated(_ providerId: String) -> Bool {
        providers[providerId]?.isAuthenticated ?? false
    }
}
