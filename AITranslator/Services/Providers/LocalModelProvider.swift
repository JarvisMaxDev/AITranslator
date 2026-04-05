import Foundation

/// Local on-device translation provider using llama.cpp inference.
///
/// `isAuthenticated` returns `true` when a GGUF model is downloaded and selected.
/// Translation runs entirely offline through ``LlamaInference``.
final class LocalModelProvider: AIProvider, @unchecked Sendable {
    let id: String
    let type: ProviderType = .local

    private let catalog: ModelCatalog
    private var inference: LlamaInference?

    var isAuthenticated: Bool {
        // Check if a model is selected (persisted in UserDefaults)
        UserDefaults.standard.string(forKey: "localModelActiveId") != nil
    }

    init(config: ProviderConfig, catalog: ModelCatalog) {
        self.id = config.id
        self.catalog = catalog
    }

    func authenticate() async throws {
        // No auth needed
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResponse {
        // Access @MainActor catalog properties from async context
        let (activeId, models, modelPathResult) = await MainActor.run {
            let aid = catalog.activeModelId
            let mdls = catalog.models
            let path: String? = if let aid, let model = mdls.first(where: { $0.id == aid }) {
                catalog.modelPath(for: model)
            } else {
                nil
            }
            return (aid, mdls, path)
        }

        guard let activeId,
              let model = models.first(where: { $0.id == activeId }),
              let modelPath = modelPathResult else {
            throw AIProviderError.apiError(
                "No local model selected. Download and select a model in Settings."
            )
        }

        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw AIProviderError.apiError(
                "Model file not found on disk. Please re-download."
            )
        }

        // Load model on first use
        if inference == nil {
            AppLogger.info("LocalModel", "Loading model into memory...", details: model.name)
            inference = try await LlamaInference(modelPath: modelPath)
        }

        let systemPrompt = buildSystemPrompt(request: request)

        // Adaptive max_tokens: use utf8 byte count for better CJK estimation
        let estimatedInputTokens = request.sourceText.utf8.count / 4
        let maxTokens = max(512, min(2048, Int(Double(estimatedInputTokens) * 1.5)))

        AppLogger.request("LocalModel", "Translating via \(model.name)",
            details: "Text: \(request.sourceText.prefix(200))\(request.sourceText.count > 200 ? "..." : "")")

        let result = try await inference!.generate(
            systemPrompt: systemPrompt,
            userPrompt: request.sourceText,
            temperature: 0.1,
            maxTokens: maxTokens
        )

        let translatedText = result.trimmingCharacters(in: .whitespacesAndNewlines)

        AppLogger.response("LocalModel", "Translation complete",
            details: "Result: \(translatedText.prefix(200))\(translatedText.count > 200 ? "..." : "")")

        return TranslationResponse(
            translatedText: translatedText,
            detectedLanguage: nil
        )
    }

    func unloadModel() async {
        await inference?.unload()
        inference = nil
        AppLogger.info("LocalModel", "Model unloaded from memory")
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
