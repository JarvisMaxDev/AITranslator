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

    /// Reference to model catalog for local provider lifecycle management
    var modelCatalog: ModelCatalog?

    /// Create and register provider from config.
    /// Skips recreation only for local provider (expensive model in RAM).
    /// Cloud providers are always refreshed to pick up credential changes.
    func setupProvider(from config: ProviderConfig) {
        if config.type == .local, providers[config.id] != nil { return }

        let provider: AIProvider
        switch config.type {
        case .qwen:
            provider = QwenProvider(config: config)
        case .anthropic:
            provider = AnthropicProvider(config: config)
        case .openai:
            provider = OpenAIProvider(config: config)
        case .gemini:
            provider = GeminiProvider(config: config)
        case .local:
            guard let catalog = modelCatalog else {
                AppLogger.shared.error("TranslationService", "Cannot create local provider: no ModelCatalog")
                return
            }
            provider = LocalModelProvider(config: config, catalog: catalog)
        }
        registerProvider(provider)
    }

    /// Unload local model from memory when switching away from local provider
    func unloadLocalModel() async {
        for provider in providers.values {
            if let localProvider = provider as? LocalModelProvider {
                await localProvider.unloadModel()
            }
        }
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

    /// Stream translation text token by token
    func translateStream(
        text: String,
        from sourceLanguage: Language,
        to targetLanguage: Language,
        using providerId: String
    ) -> AsyncThrowingStream<String, Error> {
        guard let provider = providers[providerId] else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: AIProviderError.apiError(
                    NSLocalizedString("error.provider_not_found", comment: "Provider not found")))
            }
        }

        let request = TranslationRequest(
            sourceText: text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )

        AppLogger.shared.request("Translation",
            "\(sourceLanguage.name) → \(targetLanguage.name) via \(providerId) [stream]",
            details: "Text: \(text.prefix(200))\(text.count > 200 ? "..." : "")")

        isTranslating = true
        error = nil

        return provider.translateStream(request)
    }

    /// Check if a provider is authenticated
    func isProviderAuthenticated(_ providerId: String) -> Bool {
        providers[providerId]?.isAuthenticated ?? false
    }
}
