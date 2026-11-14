import Foundation
import LlamaSwift

// MARK: - Errors

enum LlamaInferenceError: LocalizedError {
    case modelLoadFailed(path: String)
    case contextCreationFailed
    case tokenizationFailed
    case promptTooLong(tokenCount: Int, contextSize: UInt32)
    case decodeFailed(code: Int32)
    case notLoaded
    case utf8EncodingFailed
    case unsupportedChatTemplate

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path):
            return String(format: NSLocalizedString("error.local_model_load", value: "Could not load model %@. The file may be damaged, memory may be insufficient, or its format may be unsupported. See the runtime log for details.", comment: "Local model loading failed"), URL(fileURLWithPath: path).lastPathComponent)
        case .contextCreationFailed:
            return "Failed to create llama context"
        case .tokenizationFailed:
            return "Failed to tokenize prompt"
        case .promptTooLong(let tokenCount, let contextSize):
            return "Prompt is too long for local model context (\(tokenCount)/\(contextSize) tokens)"
        case .decodeFailed(let code):
            return "llama_decode returned error code \(code)"
        case .notLoaded:
            return "Model is not loaded"
        case .utf8EncodingFailed:
            return "Failed to decode token bytes as valid UTF-8"
        case .unsupportedChatTemplate:
            return NSLocalizedString("error.local_chat_template", value: "This model's chat template is not supported yet. Choose another instruction-tuned model.", comment: "Unsupported chat template")
        }
    }
}

// MARK: - Actor

/// Thread-safe wrapper around llama.cpp C API for on-device text generation.
/// Metal GPU acceleration on Apple Silicon, CPU fallback on Intel.
actor LlamaInference {

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private let architecture: String
    private let chatTemplate: String?

    private static let defaultContextSize: UInt32 = 4096

    // Global singleton init — must be called exactly once per process
    private static let backendInit: Void = {
        llama_log_set({ level, message, _ in
            guard let message else { return }
            if level == GGML_LOG_LEVEL_ERROR {
                AppLogger.error("llama.cpp", String(cString: message))
            } else if level == GGML_LOG_LEVEL_WARN {
                AppLogger.warning("llama.cpp", String(cString: message))
            }
        }, nil)
        llama_backend_init()
    }()

    init(modelPath: String) async throws {
        _ = Self.backendInit

        var modelParams = llama_model_default_params()
        #if arch(arm64)
        modelParams.n_gpu_layers = 99  // Metal GPU on Apple Silicon
        #else
        modelParams.n_gpu_layers = 0   // CPU-only on Intel
        #endif

        guard let loadedModel = llama_model_load_from_file(modelPath, modelParams) else {
            throw LlamaInferenceError.modelLoadFailed(path: modelPath)
        }
        self.model = loadedModel
        var architectureBuffer = [CChar](repeating: 0, count: 128)
        llama_model_meta_val_str(loadedModel, "general.architecture", &architectureBuffer, architectureBuffer.count)
        self.architecture = String(decoding: architectureBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        self.chatTemplate = llama_model_chat_template(loadedModel, nil).map { String(cString: $0) }

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = Self.defaultContextSize

        guard let ctx = llama_init_from_model(loadedModel, ctxParams) else {
            llama_model_free(loadedModel)
            self.model = nil
            throw LlamaInferenceError.contextCreationFailed
        }
        self.context = ctx

        AppLogger.info("LlamaInference", "Model loaded", details: modelPath)
    }

    func generate(
        systemPrompt: String,
        userPrompt: String,
        temperature: Float,
        maxTokens: Int
    ) async throws -> String {
        guard let model, let context else {
            throw LlamaInferenceError.notLoaded
        }

        let vocab = llama_model_get_vocab(model)!

        let prompt = try Self.formatChatPrompt(
            template: chatTemplate,
            architecture: architecture,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
        )

        // Tokenize
        let tokens = try tokenize(prompt: prompt, vocab: vocab)
        guard !tokens.isEmpty else {
            throw LlamaInferenceError.tokenizationFailed
        }

        let remainingContext = Int(Self.defaultContextSize) - tokens.count
        guard remainingContext > 0 else {
            throw LlamaInferenceError.promptTooLong(
                tokenCount: tokens.count,
                contextSize: Self.defaultContextSize
            )
        }
        let generationLimit = min(max(maxTokens, 0), remainingContext)
        guard generationLimit > 0 else { return "" }

        AppLogger.info("LlamaInference", "Prompt tokenized", details: "\(tokens.count) tokens")

        // Clear memory (KV cache) so each call is independent
        llama_memory_clear(llama_get_memory(context), true)

        // Long source texts must not exceed the runtime's prefill batch size.
        let batchSize = min(tokens.count, Int(llama_n_batch(context)))
        var batch = llama_batch_init(Int32(batchSize), 0, 1)
        defer { llama_batch_free(batch) }

        for start in stride(from: 0, to: tokens.count, by: batchSize) {
            try Task.checkCancellation()
            let count = min(batchSize, tokens.count - start)
            for index in 0..<count {
                let position = start + index
                batch.token[index] = tokens[position]
                batch.pos[index] = Int32(position)
                batch.n_seq_id[index] = 1
                batch.seq_id[index]![0] = 0
                batch.logits[index] = position == tokens.count - 1 ? 1 : 0
            }
            batch.n_tokens = Int32(count)
            let prefillResult = llama_decode(context, batch)
            guard prefillResult == 0 else {
                throw LlamaInferenceError.decodeFailed(code: prefillResult)
            }
        }

        // Build sampler chain
        let samplerChain = buildSamplerChain(temperature: temperature)
        defer { llama_sampler_free(samplerChain) }

        // Generation loop
        var outputBytes: [UInt8] = []
        outputBytes.reserveCapacity(generationLimit * 4)

        let eosToken = llama_vocab_eos(vocab)
        let eotToken = llama_vocab_eot(vocab)  // end-of-turn (Gemma uses this)
        var currentPos = Int32(tokens.count)

        var singleBatch = llama_batch_init(1, 0, 1)
        defer { llama_batch_free(singleBatch) }

        for _ in 0 ..< generationLimit {
            try Task.checkCancellation()
            let nextToken = llama_sampler_sample(samplerChain, context, -1)
            llama_sampler_accept(samplerChain, nextToken)

            // Stop at EOS, end-of-turn, or any end-of-generation token
            if nextToken == eosToken || nextToken == eotToken || llama_vocab_is_eog(vocab, nextToken) { break }

            // Preserve channel delimiters until post-processing, otherwise a
            // thinking block loses its boundaries and leaks into the translation.
            do {
                var tokenBytes = [CChar](repeating: 0, count: 32)
                var byteCount = llama_token_to_piece(vocab, nextToken, &tokenBytes, Int32(tokenBytes.count), 0, true)
                if byteCount < 0 {
                    tokenBytes = [CChar](repeating: 0, count: Int(-byteCount))
                    byteCount = llama_token_to_piece(vocab, nextToken, &tokenBytes, Int32(tokenBytes.count), 0, true)
                }
                if byteCount > 0 {
                    for i in 0 ..< Int(byteCount) {
                        outputBytes.append(UInt8(bitPattern: tokenBytes[i]))
                    }
                }
            }

            // Prepare next decode step
            singleBatch.token[0] = nextToken
            singleBatch.pos[0] = currentPos
            singleBatch.n_seq_id[0] = 1
            singleBatch.seq_id[0]![0] = 0
            singleBatch.logits[0] = 1
            singleBatch.n_tokens = 1
            currentPos += 1

            let stepResult = llama_decode(context, singleBatch)
            guard stepResult == 0 else {
                throw LlamaInferenceError.decodeFailed(code: stepResult)
            }
        }

        // UTF-8 decode
        if let output = String(bytes: outputBytes, encoding: .utf8) {
            AppLogger.info("LlamaInference", "Generation complete", details: "\(outputBytes.count) bytes")
            return output
        }

        // Lossy fallback
        let lossy = String(decoding: outputBytes, as: UTF8.self)
        if !lossy.isEmpty {
            AppLogger.warning("LlamaInference", "Used lossy UTF-8 decode")
            return lossy
        }
        throw LlamaInferenceError.utf8EncodingFailed
    }

    func unload() {
        if let ctx = context {
            llama_free(ctx)
            self.context = nil
        }
        if let mdl = model {
            llama_model_free(mdl)
            self.model = nil
        }
        AppLogger.info("LlamaInference", "Model unloaded")
    }

    // Note: Always call unload() before letting the instance go.
    // Actor deinit cannot access isolated state safely in Swift 6.

    // MARK: - Private

    /// Render text-only, single-turn instructions using the model's metadata.
    /// The C template API does not execute arbitrary Jinja or support Gemma 4.
    nonisolated static func formatChatPrompt(
        template: String?,
        architecture: String,
        systemPrompt: String,
        userPrompt: String
    ) throws -> String {
        guard let template, !template.isEmpty else {
            throw LlamaInferenceError.unsupportedChatTemplate
        }
        if architecture == "gemma4" {
            // Canonical text-only template, enable_thinking=false. The tokenizer
            // inserts BOS. Gemma 4 supports a dedicated system turn.
            return "<|turn>system\n\(systemPrompt)<turn|>\n<|turn>user\n\(userPrompt)<turn|>\n<|turn>model\n"
        }

        return try "system".withCString { systemRole in
            try "user".withCString { userRole in
                try systemPrompt.withCString { systemContent in
                    try userPrompt.withCString { userContent in
                        let messages = [
                            llama_chat_message(role: systemRole, content: systemContent),
                            llama_chat_message(role: userRole, content: userContent)
                        ]
                        var buffer = [CChar](repeating: 0, count: systemPrompt.utf8.count + userPrompt.utf8.count + 512)
                        var count = llama_chat_apply_template(template, messages, messages.count, true, &buffer, Int32(buffer.count))
                        guard count > 0 else { throw LlamaInferenceError.unsupportedChatTemplate }
                        if count >= buffer.count {
                            buffer = [CChar](repeating: 0, count: Int(count) + 1)
                            count = llama_chat_apply_template(template, messages, messages.count, true, &buffer, Int32(buffer.count))
                        }
                        guard count > 0, count < buffer.count else { throw LlamaInferenceError.unsupportedChatTemplate }
                        return String(decoding: buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    }
                }
            }
        }
    }

    private func tokenize(
        prompt: String,
        vocab: OpaquePointer
    ) throws -> [llama_token] {
        let estimatedCount = Int(prompt.utf8.count) + 16
        var tokenBuffer = [llama_token](repeating: 0, count: estimatedCount)

        let count = llama_tokenize(
            vocab,
            prompt,
            Int32(prompt.utf8.count),
            &tokenBuffer,
            Int32(estimatedCount),
            true,
            true
        )

        guard count >= 0 else {
            throw LlamaInferenceError.tokenizationFailed
        }

        var tokens = Array(tokenBuffer.prefix(Int(count)))
        let bos = llama_vocab_bos(vocab)
        if tokens.count > 1, tokens[0] == bos, tokens[1] == bos {
            tokens.removeFirst()
        }
        return tokens
    }

    private func buildSamplerChain(
        temperature: Float
    ) -> UnsafeMutablePointer<llama_sampler> {
        let sparams = llama_sampler_chain_default_params()
        let chain = llama_sampler_chain_init(sparams)!

        // Order per llama.h example: top_k → top_p → temp → dist
        if temperature > 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_temp(temperature))
            llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        }

        return chain
    }
}
