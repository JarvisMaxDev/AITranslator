import Foundation
import Darwin

// Compiled with the app's actual LlamaInference and its pinned XCFramework.
// Run one model per process so peak resident memory is not inherited from another model.
@main
struct TranslationBenchmark {
    struct Sample: Codable {
        let id: String
        let sourceLanguage: String
        let targetLanguage: String
        let text: String
    }

    struct Result: Codable {
        let sample: Sample
        let seconds: Double
        let rawOutput: String
    }

    struct Report: Codable {
        let modelPath: String
        let runtime: String
        let loadSeconds: Double
        let peakResidentBytes: Int
        let temperature: Float
        let results: [Result]
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 4 else {
            throw NSError(domain: "Usage: translation-benchmark MODEL.gguf SAMPLES.json OUTPUT.json", code: 1)
        }
        let modelPath = CommandLine.arguments[1]
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        let start = Date()
        let inference = try await LlamaInference(modelPath: modelPath)
        let loadSeconds = Date().timeIntervalSince(start)
        do {
            // Exclude first-inference Metal pipeline warmup from per-sample timings.
            _ = try await inference.generate(systemPrompt: "Translate to Russian. Output only the translation.", userPrompt: "Good morning.", temperature: 0, maxTokens: 64)
            var results: [Result] = []
            for sample in samples {
                let prompt = LocalTranslationPrompt(text: sample.text, sourceLanguage: sample.sourceLanguage, targetLanguage: sample.targetLanguage)
                let started = Date()
                let output = try await inference.generate(systemPrompt: prompt.system, userPrompt: prompt.user, temperature: 0, maxTokens: prompt.maxTokens)
                results.append(Result(sample: sample, seconds: Date().timeIntervalSince(started), rawOutput: output))
                print("Finished \(sample.id): \(results.last!.seconds)s")
            }
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let report = Report(modelPath: modelPath, runtime: "llama.swift 2.10549.0 / llama.cpp b10549", loadSeconds: loadSeconds, peakResidentBytes: usage.ru_maxrss, temperature: 0, results: results)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(report).write(to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .atomic)
            await inference.unload()
        } catch {
            await inference.unload()
            throw error
        }
    }
}
