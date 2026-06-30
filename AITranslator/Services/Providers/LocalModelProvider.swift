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

        let systemPrompt = buildSystemPrompt(request: request)

        // Adaptive max_tokens: use utf8 byte count for better CJK estimation
        let estimatedInputTokens = request.sourceText.utf8.count / 4
        let maxTokens = max(512, min(2048, Int(Double(estimatedInputTokens) * 1.5)))

        AppLogger.request("LocalModel", "Translating via \(model.name)",
            details: "Input length: \(request.sourceText.count) characters")

        let result = try await inference.generate(
            systemPrompt: systemPrompt,
            userPrompt: request.sourceText,
            temperature: 0.1,
            maxTokens: maxTokens
        )

        let translatedText = Self.cleanModelOutput(result)

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

        // Remove Qwen3 thinking blocks: <think>...</think>
        while let thinkStart = text.range(of: "<think>") {
            guard let thinkEnd = text.range(of: "</think>", range: thinkStart.upperBound..<text.endIndex) else {
                text.removeSubrange(thinkStart.lowerBound..<text.endIndex)
                break
            }
            text.removeSubrange(thinkStart.lowerBound..<thinkEnd.upperBound)
        }

        // Remove common special tokens that leak into output
        let junkPatterns = [
            "<|im_start|>", "<|im_end|>",
            "<|endoftext|>", "<|end|>",
            "<start_of_turn>", "<end_of_turn>",
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

        // If model started explaining instead of just translating,
        // take only the first non-empty paragraph (the actual translation).
        // Heuristic: if output contains English explanation after translation,
        // the explanation usually starts with a sentence containing common words.
        let explanationMarkers = [
            "This text is already",
            "This is the final",
            "The translation is",
            "Here is the translation",
            "This translation is",
            "The word ",
            "The Russian ",
            "Note:",
            "I hope",
            "If you need",
            "Let me know",
            "Feel free",
        ]

        for marker in explanationMarkers {
            if let range = text.range(of: marker) {
                if range.lowerBound != text.startIndex {
                    text = String(text[text.startIndex..<range.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                break
            }
        }

        // Remove duplicate lines (some models repeat the translation)
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.count >= 2 {
            var seen = Set<String>()
            var unique: [String] = []
            for line in lines {
                if seen.insert(line).inserted {
                    unique.append(line)
                }
            }
            text = unique.joined(separator: "\n")
        }

        return text
    }

    private func buildSystemPrompt(request: TranslationRequest) -> String {
        let sourceLang = request.sourceLanguage.code == "auto"
            ? "auto-detected language"
            : request.sourceLanguage.name
        let targetLang = request.targetLanguage.name

        return """
        Translate from \(sourceLang) to \(targetLang). Output ONLY the translation, nothing else. No explanations.
        """
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
