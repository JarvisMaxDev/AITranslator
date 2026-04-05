import Foundation
import LlamaSwift

// MARK: - Errors

enum LlamaInferenceError: LocalizedError {
    case modelLoadFailed(path: String)
    case contextCreationFailed
    case tokenizationFailed
    case decodeFailed(code: Int32)
    case notLoaded
    case utf8EncodingFailed

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path):
            return "Failed to load GGUF model from: \(path)"
        case .contextCreationFailed:
            return "Failed to create llama context"
        case .tokenizationFailed:
            return "Failed to tokenize prompt"
        case .decodeFailed(let code):
            return "llama_decode returned error code \(code)"
        case .notLoaded:
            return "Model is not loaded"
        case .utf8EncodingFailed:
            return "Failed to decode token bytes as valid UTF-8"
        }
    }
}

// MARK: - Actor

/// Thread-safe wrapper around llama.cpp C API for on-device text generation.
/// Metal GPU acceleration on Apple Silicon, CPU fallback on Intel.
actor LlamaInference {

    private var model: OpaquePointer?
    private var context: OpaquePointer?

    private static let defaultContextSize: UInt32 = 4096

    // Global singleton init — must be called exactly once per process
    private static let backendInit: Void = {
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

        // Build ChatML prompt
        let prompt = """
        <|im_start|>system
        \(systemPrompt)<|im_end|>
        <|im_start|>user
        \(userPrompt)<|im_end|>
        <|im_start|>assistant

        """

        // Tokenize
        let tokens = try tokenize(prompt: prompt, vocab: vocab, addBos: true)
        AppLogger.info("LlamaInference", "Prompt tokenized", details: "\(tokens.count) tokens")

        // Clear memory (KV cache) so each call is independent
        llama_memory_clear(llama_get_memory(context), true)

        // Decode prompt tokens in a single batch
        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }

        for (index, token) in tokens.enumerated() {
            batch.token[index] = token
            batch.pos[index] = Int32(index)
            batch.n_seq_id[index] = 1
            batch.seq_id[index]![0] = 0
            batch.logits[index] = 0
        }
        batch.logits[tokens.count - 1] = 1
        batch.n_tokens = Int32(tokens.count)

        let prefillResult = llama_decode(context, batch)
        guard prefillResult == 0 else {
            throw LlamaInferenceError.decodeFailed(code: prefillResult)
        }

        // Build sampler chain
        let samplerChain = buildSamplerChain(temperature: temperature)
        defer { llama_sampler_free(samplerChain) }

        // Generation loop
        var outputBytes: [UInt8] = []
        outputBytes.reserveCapacity(maxTokens * 4)

        let eosToken = llama_vocab_eos(vocab)
        var currentPos = Int32(tokens.count)

        var singleBatch = llama_batch_init(1, 0, 1)
        defer { llama_batch_free(singleBatch) }

        for _ in 0 ..< maxTokens {
            let nextToken = llama_sampler_sample(samplerChain, context, -1)
            llama_sampler_accept(samplerChain, nextToken)

            if nextToken == eosToken { break }

            // Convert token to bytes
            var tokenBytes = [CChar](repeating: 0, count: 32)
            let byteCount = llama_token_to_piece(vocab, nextToken, &tokenBytes, 32, 0, false)
            if byteCount > 0 {
                for i in 0 ..< Int(byteCount) {
                    outputBytes.append(UInt8(bitPattern: tokenBytes[i]))
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

    private func tokenize(
        prompt: String,
        vocab: OpaquePointer,
        addBos: Bool
    ) throws -> [llama_token] {
        let estimatedCount = Int(prompt.utf8.count) + 16
        var tokenBuffer = [llama_token](repeating: 0, count: estimatedCount)

        let count = llama_tokenize(
            vocab,
            prompt,
            Int32(prompt.utf8.count),
            &tokenBuffer,
            Int32(estimatedCount),
            addBos,
            false
        )

        guard count >= 0 else {
            throw LlamaInferenceError.tokenizationFailed
        }

        return Array(tokenBuffer.prefix(Int(count)))
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
