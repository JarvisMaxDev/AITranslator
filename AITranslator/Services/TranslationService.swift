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
            AppLogger.shared.error("Translation", "Provider '\(providerId)' not found")
            return nil
        }

        // Skip isAuthenticated check — auto-refresh handles expired tokens

        isTranslating = true
        error = nil

        let request = TranslationRequest(
            sourceText: text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )

        AppLogger.shared.request("Translation",
            "\(sourceLanguage.name) → \(targetLanguage.name) via \(providerId)",
            details: "Text: \(text.prefix(200))\(text.count > 200 ? "..." : "")")

        do {
            let response = try await provider.translate(request)
            isTranslating = false
            AppLogger.shared.success("Translation",
                "Translated successfully",
                details: "Result: \(response.translatedText.prefix(200))\(response.translatedText.count > 200 ? "..." : "")")
            return response
        } catch let providerError as AIProviderError {
            isTranslating = false
            self.error = providerError.errorDescription
            AppLogger.shared.error("Translation",
                "Provider error: \(providerError.errorDescription ?? "unknown")",
                details: String(describing: providerError))
            return nil
        } catch {
            isTranslating = false
            self.error = NSLocalizedString("error.translation_failed", comment: "Translation failed")
            AppLogger.shared.error("Translation",
                "Unexpected error",
                details: error.localizedDescription)
            return nil
        }
    }

    /// Check if a provider is authenticated
    func isProviderAuthenticated(_ providerId: String) -> Bool {
        providers[providerId]?.isAuthenticated ?? false
    }
}
