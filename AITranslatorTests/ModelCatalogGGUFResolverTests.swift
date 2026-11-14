import XCTest
@testable import AI_Translator

@MainActor
final class ModelCatalogGGUFResolverTests: XCTestCase {

    func testNormalizeHuggingFaceRepoAcceptsRepoAndURLs() throws {
        let catalog = ModelCatalog()

        XCTAssertEqual(
            try catalog.normalizeHuggingFaceRepo(" google/gemma-4-E4B-it-qat-q4_0-unquantized "),
            "google/gemma-4-E4B-it-qat-q4_0-unquantized"
        )
        XCTAssertEqual(
            try catalog.normalizeHuggingFaceRepo("https://huggingface.co/google/gemma-4-E4B-it-qat-q4_0-unquantized/tree/main"),
            "google/gemma-4-E4B-it-qat-q4_0-unquantized"
        )
        XCTAssertEqual(
            try catalog.normalizeHuggingFaceRepo("huggingface.co/ggml-org/gpt-oss-20b-GGUF"),
            "ggml-org/gpt-oss-20b-GGUF"
        )
    }

    func testNormalizeHuggingFaceRepoRejectsUnsafePathComponents() {
        let catalog = ModelCatalog()

        XCTAssertThrowsError(try catalog.normalizeHuggingFaceRepo("../model"))
        XCTAssertThrowsError(try catalog.normalizeHuggingFaceRepo("owner/.."))
        XCTAssertThrowsError(try catalog.normalizeHuggingFaceRepo("https://huggingface.co/../model"))
    }

    func testGeneratedGGUFRepoCandidatesIncludeGoogleQATRepo() {
        let catalog = ModelCatalog()

        let candidates = catalog.generatedGGUFRepoCandidates(
            for: "google/gemma-4-E4B-it-qat-q4_0-unquantized"
        )

        XCTAssertTrue(candidates.contains("google/gemma-4-E4B-it-qat-q4_0-gguf"))
        XCTAssertEqual(candidates.count, Set(candidates).count)
    }

    func testBaseModelReposReadsTagsAndCardData() {
        let catalog = ModelCatalog()

        let model: [String: Any] = [
            "tags": [
                "base_model:quantized:openai/gpt-oss-20b",
                "base_model:finetune:ignored/model"
            ],
            "cardData": [
                "base_model": ["google/gemma-4-E4B-it", "openai/gpt-oss-20b"]
            ]
        ]

        XCTAssertEqual(
            catalog.baseModelRepos(from: model),
            ["openai/gpt-oss-20b", "google/gemma-4-E4B-it"]
        )
    }

    func testBuildGGUFCandidatesFiltersUnsupportedFiles() {
        let catalog = ModelCatalog()

        let model: [String: Any] = [
            "siblings": [
                ["rfilename": "model-Q4_0.gguf"],
                ["rfilename": "mmproj-model.gguf"],
                ["rfilename": "model-00001-of-00002.gguf"],
                ["rfilename": "MTP/model.gguf"],
                ["rfilename": "mtp-model.gguf"],
                ["rfilename": "model-MTP.gguf"],
                ["rfilename": "dflash-gemma-4-26B-A4B-it-Q8_0.gguf"],
                ["rfilename": "config.json"]
            ],
            "downloads": 42,
            "tags": []
        ]

        let result = catalog.buildGGUFCandidates(
            from: model,
            repo: "google/source-GGUF",
            sourceRepo: "google/source",
            referenceRepos: ["google/source"]
        )

        XCTAssertEqual(result.candidates.map(\.remoteFileName), ["model-Q4_0.gguf"])
        XCTAssertEqual(result.unsupportedCount, 6)
        XCTAssertEqual(result.candidates.first?.sourceKind, .sameOwner)
        XCTAssertEqual(result.candidates.first?.localFileName, "google-source-gguf--model-Q4_0.gguf")
    }

    func testBuildGGUFCandidatesDoesNotBlacklistSupportedArchitecturesByName() {
        let catalog = ModelCatalog()

        let gemma4 = catalog.buildGGUFCandidates(
            from: ggufModel(downloads: 10, tags: ["base_model:quantized:google/gemma-4-E4B-it-qat-q4_0-unquantized"]),
            repo: "google/gemma-4-E4B-it-qat-q4_0-gguf",
            sourceRepo: "google/gemma-4-E4B-it-qat-q4_0-unquantized",
            referenceRepos: ["google/gemma-4-E4B-it-qat-q4_0-unquantized"]
        )
        let gptOSS = catalog.buildGGUFCandidates(
            from: ggufModel(downloads: 10, tags: ["base_model:quantized:openai/gpt-oss-20b"]),
            repo: "ggml-org/gpt-oss-20b-GGUF",
            sourceRepo: "openai/gpt-oss-20b",
            referenceRepos: ["openai/gpt-oss-20b"]
        )

        XCTAssertEqual(gemma4.candidates.map(\.remoteFileName), ["model-Q4_0.gguf"])
        XCTAssertEqual(gptOSS.candidates.map(\.remoteFileName), ["model-Q4_0.gguf"])
    }

    func testBuildGGUFCandidatesKeepsRuntimeSupportedGemma3AndQwen() {
        let catalog = ModelCatalog()

        let gemma3 = catalog.buildGGUFCandidates(
            from: ggufModel(downloads: 10, tags: ["base_model:quantized:google/gemma-3-4b-it"]),
            repo: "ggml-org/gemma-3-4b-it-GGUF",
            sourceRepo: "google/gemma-3-4b-it",
            referenceRepos: ["google/gemma-3-4b-it"]
        )
        let qwen = catalog.buildGGUFCandidates(
            from: ggufModel(downloads: 10, tags: ["base_model:quantized:Qwen/Qwen3-4B-Instruct"]),
            repo: "Qwen/Qwen3-4B-Instruct-GGUF",
            sourceRepo: "Qwen/Qwen3-4B-Instruct",
            referenceRepos: ["Qwen/Qwen3-4B-Instruct"]
        )

        XCTAssertEqual(gemma3.candidates.map(\.remoteFileName), ["model-Q4_0.gguf"])
        XCTAssertEqual(qwen.candidates.map(\.remoteFileName), ["model-Q4_0.gguf"])
    }

    func testRuntimeFilterDoesNotRejectGemma4BSubstring() {
        let catalog = ModelCatalog()

        let result = catalog.buildGGUFCandidates(
            from: ggufModel(downloads: 10, tags: ["base_model:quantized:example/gemma-4b"]),
            repo: "community/gemma-4b-GGUF",
            sourceRepo: "example/gemma-4b",
            referenceRepos: ["example/gemma-4b"]
        )

        XCTAssertEqual(result.candidates.map(\.remoteFileName), ["model-Q4_0.gguf"])
    }

    func testRefreshStatesClearsActiveModelWhenFileIsMissing() throws {
        let defaults = UserDefaults.standard
        let activeKey = "localModelActiveId"
        let customModelsKey = "localModelCustomModels"
        let previousActiveModelId = defaults.string(forKey: activeKey)
        let previousCustomModels = defaults.data(forKey: customModelsKey)
        defer {
            if let previousActiveModelId {
                defaults.set(previousActiveModelId, forKey: activeKey)
            } else {
                defaults.removeObject(forKey: activeKey)
            }
            if let previousCustomModels {
                defaults.set(previousCustomModels, forKey: customModelsKey)
            } else {
                defaults.removeObject(forKey: customModelsKey)
            }
        }

        let id = "custom-missing-active-\(UUID().uuidString)"
        let missingModel = LocalModel(
            id: id,
            name: "Missing Active Test",
            fileName: "missing-active-\(UUID().uuidString).gguf",
            downloadURL: "https://huggingface.co/example/model/resolve/main/model.gguf",
            sizeBytes: 4,
            description: "Test model",
            isBuiltIn: false
        )
        defaults.set(try JSONEncoder().encode([missingModel]), forKey: customModelsKey)
        defaults.set(id, forKey: activeKey)

        let catalog = ModelCatalog()

        XCTAssertNil(catalog.activeModelId)
        XCTAssertEqual(catalog.modelStates[id], .notDownloaded)
        XCTAssertNil(defaults.string(forKey: activeKey))
    }

    func testLocalModelOutputKeepsTranslationAfterLeadingMarker() {
        XCTAssertEqual(
            LocalModelProvider.cleanModelOutput("Translation: Hello"),
            "Hello"
        )
        XCTAssertEqual(
            LocalModelProvider.cleanModelOutput("Here is the translation: Bonjour"),
            "Bonjour"
        )
    }

    func testLocalModelOutputRemovesUnclosedThinkingBlock() {
        XCTAssertEqual(
            LocalModelProvider.cleanModelOutput("<think>reasoning without closing tag"),
            ""
        )
        XCTAssertEqual(
            LocalModelProvider.cleanModelOutput("<think>reasoning</think>Hallo"),
            "Hallo"
        )
    }

    func testLocalModelOutputHandlesMalformedThinkingBlock() {
        XCTAssertEqual(
            LocalModelProvider.cleanModelOutput("</think> visible <think>hidden"),
            "</think> visible"
        )
    }

    func testGemma4PromptUsesDedicatedSystemTurnWithoutThinking() throws {
        let prompt = try LlamaInference.formatChatPrompt(
            template: "{{ bos_token }}<|turn>", architecture: "gemma4",
            systemPrompt: "Translate to Russian.", userPrompt: "Hello"
        )
        XCTAssertEqual(prompt, "<|turn>system\nTranslate to Russian.<turn|>\n<|turn>user\nHello<turn|>\n<|turn>model\n")
        XCTAssertFalse(prompt.contains("<|think|>"))
        XCTAssertFalse(prompt.contains("<bos>"))
    }

    func testGemma3PromptMergesSystemIntoUserTurn() throws {
        let prompt = try LlamaInference.formatChatPrompt(
            template: "gemma", architecture: "gemma3",
            systemPrompt: "Translate to Russian.", userPrompt: "Hello"
        )
        XCTAssertEqual(prompt, "<start_of_turn>user\nTranslate to Russian.\n\nHello<end_of_turn>\n<start_of_turn>model\n")
    }

    func testUnsupportedOrMissingTemplateDoesNotSilentlyUsePlainText() {
        for template in [nil, "", "unsupported-template"] as [String?] {
            XCTAssertThrowsError(try LlamaInference.formatChatPrompt(
                template: template, architecture: "unknown",
                systemPrompt: "Translate", userPrompt: "Hello"
            ))
        }
    }

    func testChatTemplatePreservesLongUnicodeInput() throws {
        let source = String(repeating: "Привет 世界 👋\n", count: 200)
        let prompt = try LlamaInference.formatChatPrompt(
            template: "chatml", architecture: "qwen2",
            systemPrompt: "Translate", userPrompt: source
        )
        XCTAssertTrue(prompt.contains(source))
        XCTAssertTrue(prompt.hasSuffix("<|im_start|>assistant\n"))
    }

    func testLocalModelOutputRemovesGemma4ThinkingWithoutLosingAnswer() {
        XCTAssertEqual(LocalModelProvider.cleanModelOutput("<|channel>thought\nprivate reasoning<channel|>Привет!<turn|>"), "Привет!")
        XCTAssertEqual(LocalModelProvider.cleanModelOutput("<|channel>thought\nunfinished reasoning"), "")
    }

    func testLocalModelOutputPreservesParagraphsRepetitionAndEnglishPhrases() {
        let text = "Thank you.\n\nThank you.\n\nNote: I hope this helps. Let me know if you need anything."
        XCTAssertEqual(LocalModelProvider.cleanModelOutput(text), text)
    }

    func testLocalModelOutputKeepsOnlyHarmonyFinalChannel() {
        XCTAssertEqual(LocalModelProvider.cleanModelOutput("<|channel|>analysis<|message|>reasoning<|end|><|start|>assistant<|channel|>final<|message|>Привет!<|return|>"), "Привет!")
        XCTAssertEqual(LocalModelProvider.cleanModelOutput("<|channel|>final<|message|>Hello<|return|>"), "Hello")
        XCTAssertEqual(LocalModelProvider.cleanModelOutput("<|channel|>analysis<|message|>unfinished reasoning"), "")
        XCTAssertEqual(LocalModelProvider.cleanModelOutput("<|meta_sep|>analysis<|im_sep|>reasoning<|im_end|><|im_start|>assistant<|meta_sep|>final<|im_sep|>Hello<|fim_suffix|>"), "Hello")
    }

    func testSortedGGUFCandidatesPrefersGGMLOverCommunityForExactBaseModel() {
        let catalog = ModelCatalog()

        let sourceRepo = "meta-llama/Llama-3.1-8B-Instruct"
        let referenceRepos = [sourceRepo]
        let ggml = catalog.buildGGUFCandidates(
            from: ggufModel(downloads: 10, tags: ["base_model:quantized:\(sourceRepo)"]),
            repo: "ggml-org/Llama-3.1-8B-Instruct-GGUF",
            sourceRepo: sourceRepo,
            referenceRepos: referenceRepos
        ).candidates
        let community = catalog.buildGGUFCandidates(
            from: ggufModel(downloads: 10_000, tags: ["base_model:quantized:\(sourceRepo)"]),
            repo: "community/Llama-3.1-8B-Instruct-GGUF",
            sourceRepo: sourceRepo,
            referenceRepos: referenceRepos
        ).candidates

        let sorted = catalog.sortedGGUFCandidates(community + ggml)

        XCTAssertEqual(sorted.first?.repo, "ggml-org/Llama-3.1-8B-Instruct-GGUF")
        XCTAssertEqual(sorted.first?.sourceKind, .ggml)
    }

    func testRemovingSelectedLastProviderClearsPersistedSelection() throws {
        let defaults = UserDefaults.standard
        let providerConfigsKey = Constants.UserDefaultsKeys.providerConfigs
        let selectedProviderKey = Constants.UserDefaultsKeys.selectedProviderId
        let previousProviderConfigs = defaults.data(forKey: providerConfigsKey)
        let previousSelectedProviderId = defaults.string(forKey: selectedProviderKey)
        defer {
            if let previousProviderConfigs {
                defaults.set(previousProviderConfigs, forKey: providerConfigsKey)
            } else {
                defaults.removeObject(forKey: providerConfigsKey)
            }
            if let previousSelectedProviderId {
                defaults.set(previousSelectedProviderId, forKey: selectedProviderKey)
            } else {
                defaults.removeObject(forKey: selectedProviderKey)
            }
        }

        var provider = ProviderConfig(type: .openai)
        provider.id = "provider-\(UUID().uuidString)"
        defaults.set(try JSONEncoder().encode([provider]), forKey: providerConfigsKey)
        defaults.set(provider.id, forKey: selectedProviderKey)

        let settings = SettingsViewModel()
        settings.removeProvider(id: provider.id)

        XCTAssertTrue(settings.providerConfigs.isEmpty)
        XCTAssertNil(settings.selectedProviderId)
        XCTAssertNil(defaults.string(forKey: selectedProviderKey))
    }

    func testLoadConfigsReplacesStaleSelectedProviderId() throws {
        let defaults = UserDefaults.standard
        let providerConfigsKey = Constants.UserDefaultsKeys.providerConfigs
        let selectedProviderKey = Constants.UserDefaultsKeys.selectedProviderId
        let previousProviderConfigs = defaults.data(forKey: providerConfigsKey)
        let previousSelectedProviderId = defaults.string(forKey: selectedProviderKey)
        defer {
            if let previousProviderConfigs {
                defaults.set(previousProviderConfigs, forKey: providerConfigsKey)
            } else {
                defaults.removeObject(forKey: providerConfigsKey)
            }
            if let previousSelectedProviderId {
                defaults.set(previousSelectedProviderId, forKey: selectedProviderKey)
            } else {
                defaults.removeObject(forKey: selectedProviderKey)
            }
        }

        var provider = ProviderConfig(type: .anthropic)
        provider.id = "provider-\(UUID().uuidString)"
        defaults.set(try JSONEncoder().encode([provider]), forKey: providerConfigsKey)
        defaults.set("missing-provider", forKey: selectedProviderKey)

        let settings = SettingsViewModel()

        XCTAssertEqual(settings.selectedProviderId, provider.id)
        XCTAssertEqual(defaults.string(forKey: selectedProviderKey), provider.id)
    }

    private func ggufModel(downloads: Int, tags: [String]) -> [String: Any] {
        [
            "siblings": [["rfilename": "model-Q4_0.gguf"]],
            "downloads": downloads,
            "tags": tags
        ]
    }
}
