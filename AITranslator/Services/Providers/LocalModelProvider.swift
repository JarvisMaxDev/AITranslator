import Foundation

/// Local on-device translation provider using llama.cpp inference.
///
/// `isAuthenticated` returns `true` when a GGUF model is downloaded and selected.
/// Translation runs entirely offline through ``LlamaInference``.
final class LocalModelProvider: AIProvider, @unchecked Sendable {
    let id: String
    let type: ProviderType = .local

    private let catalog: ModelCatalog
    private let inferenceState = LocalModelProviderState()

    var isAuthenticated: Bool {
        // Check if a model is selected (persisted in UserDefaults)
        UserDefaults.standard.string(forKey: "localModelActiveId") != nil
    }

    init(config: ProviderConfig, catalog: ModelCatalog) {
        self.id = config.id
        self.catalog = catalog
    }

    deinit {
        Task { [inferenceState] in
            await inferenceState.unload()
        }
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

        let inference = try await inferenceState.inference(for: modelPath, modelName: model.name)

        let prompt = LocalTranslationPrompt(
            text: request.sourceText,
            sourceLanguage: request.sourceLanguage.code == "auto" ? "the auto-detected language" : request.sourceLanguage.name,
            targetLanguage: request.targetLanguage.name
        )

        AppLogger.request("LocalModel", "Translating via \(model.name)",
            details: "Input length: \(request.sourceText.count) characters")

        let result = try await inference.generate(
            systemPrompt: prompt.system,
            userPrompt: prompt.user,
            temperature: 0,
            maxTokens: prompt.maxTokens
        )

        let translatedText = Self.cleanModelOutput(result)
        guard !translatedText.isEmpty else {
            throw AIProviderError.apiError(NSLocalizedString("error.local_no_translation", value: "The model did not produce a final translation. Try another instruction-tuned model or a shorter text.", comment: "Missing final model response"))
        }

        AppLogger.response("LocalModel", "Translation complete",
            details: "Output length: \(translatedText.count) characters")

        return TranslationResponse(
            translatedText: translatedText,
            detectedLanguage: nil
        )
    }

    func unloadModel() async {
        await inferenceState.unload()
        AppLogger.info("LocalModel", "Model unloaded from memory")
    }

    // MARK: - Private

    /// Remove model-specific tags and post-process output to extract clean translation.
    static func cleanModelOutput(_ raw: String) -> String {
        var text = raw

        // Harmony responses can contain analysis followed by a separate final
        // message. Never expose analysis, including an interrupted response.
        for channelToken in ["<|channel|>", "<|meta_sep|>"] where text.contains(channelToken) {
            let messageToken = channelToken == "<|channel|>" ? "<|message|>" : "<|im_sep|>"
            guard let final = text.range(of: channelToken + "final" + messageToken) else { return "" }
            text = String(text[final.upperBound...])
            if let end = text.range(of: "<|end|>") {
                text = String(text[..<end.lowerBound])
            }
        }

        // Remove explicit reasoning blocks before stripping control tokens.
        for (start, end) in [("<think>", "</think>"), ("<|channel>thought", "<channel|>")] {
            while let thinkStart = text.range(of: start) {
                guard let thinkEnd = text.range(of: end, range: thinkStart.upperBound..<text.endIndex) else {
                    text.removeSubrange(thinkStart.lowerBound..<text.endIndex)
                    break
                }
                text.removeSubrange(thinkStart.lowerBound..<thinkEnd.upperBound)
            }
        }

        // Remove common special tokens that leak into output
        let junkPatterns = [
            "<|im_start|>", "<|im_end|>",
            "<|endoftext|>", "<|end|>",
            "<start_of_turn>", "<end_of_turn>",
            "<|turn>", "<turn|>", "<|channel>final", "<channel|>",
            "<bos>", "<eos>",
            "<|return|>", "<|fim_suffix|>",
        ]
        for pattern in junkPatterns {
            text = text.replacingOccurrences(of: pattern, with: "")
        }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let translationPrefixes = [
            "Translation:",
            "translation:",
            "The translation is",
            "Here is the translation",
            "This translation is",
            "This is the final translation"
        ]
        for prefix in translationPrefixes where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix(":") || text.hasPrefix("-") {
                text.removeFirst()
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            break
        }

        // Paragraphs, repeated lines and phrases such as "Note:" or "I hope"
        // can be part of the source. Never guess which translated prose to cut.
        return text
    }

}

private actor LocalModelProviderState {
    private var inference: LlamaInference?
    private var loadedModelPath: String?
    private var loadingTask: Task<LlamaInference, Error>?
    private var loadingModelPath: String?

    func inference(for modelPath: String, modelName: String) async throws -> LlamaInference {
        if let inference, loadedModelPath == modelPath {
            return inference
        }

        if let loadingTask, loadingModelPath == modelPath {
            do {
                let loaded = try await loadingTask.value
                inference = loaded
                loadedModelPath = modelPath
                self.loadingTask = nil
                loadingModelPath = nil
                return loaded
            } catch {
                self.loadingTask = nil
                loadingModelPath = nil
                loadedModelPath = nil
                throw error
            }
        }

        if let loadingTask {
            self.loadingTask = nil
            loadingModelPath = nil
            loadingTask.cancel()
            if let loaded = try? await loadingTask.value {
                await loaded.unload()
            }
        }

        if let inference {
            AppLogger.info("LocalModel", "Model changed, unloading previous...")
            await inference.unload()
        }

        AppLogger.info("LocalModel", "Loading model into memory...", details: modelName)
        let task = Task { try await LlamaInference(modelPath: modelPath) }
        loadingTask = task
        loadingModelPath = modelPath

        do {
            let loaded = try await task.value
            inference = loaded
            loadedModelPath = modelPath
            loadingTask = nil
            loadingModelPath = nil
            return loaded
        } catch {
            loadingTask = nil
            loadingModelPath = nil
            loadedModelPath = nil
            throw error
        }
    }

    func unload() async {
        let task = loadingTask
        loadingTask = nil
        loadingModelPath = nil
        task?.cancel()
        if let task, let loaded = try? await task.value {
            await loaded.unload()
        }
        await inference?.unload()
        inference = nil
        loadedModelPath = nil
    }
}
