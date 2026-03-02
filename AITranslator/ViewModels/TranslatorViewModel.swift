import SwiftUI
import Combine
import NaturalLanguage

/// ViewModel for the main translator view
@MainActor
final class TranslatorViewModel: ObservableObject {
    @Published var sourceText: String = ""
    @Published var translatedText: String = ""
    @Published var sourceLanguage: Language = .autoDetect
    @Published var targetLanguage: Language = LanguageList.all.first(where: { $0.code == "ru" }) ?? LanguageList.all[1]
    @Published var isTranslating: Bool = false
    @Published var error: String?
    @Published var characterCount: Int = 0
    /// Detected language when sourceLanguage is Auto Detect
    @Published var detectedLanguage: Language?

    private let translationService = TranslationService()
    private let settingsViewModel: SettingsViewModel
    private var cancellables = Set<AnyCancellable>()
    private let recognizer = NLLanguageRecognizer()

    init(settingsViewModel: SettingsViewModel) {
        self.settingsViewModel = settingsViewModel

        // Setup providers from config
        for config in settingsViewModel.providerConfigs where config.isEnabled {
            translationService.setupProvider(from: config)
        }

        // Track character count
        $sourceText
            .map { $0.count }
            .assign(to: &$characterCount)

        // Auto-detect language when text changes and source is Auto Detect
        $sourceText
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .combineLatest($sourceLanguage)
            .sink { [weak self] text, lang in
                guard let self else { return }
                if lang.code == "auto" && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.detectedLanguage = self.detectLanguage(from: text)
                } else {
                    self.detectedLanguage = nil
                }
            }
            .store(in: &cancellables)

        // Restore saved language preferences
        restoreLanguagePreferences()
    }

    /// Detect language from text using NLLanguageRecognizer
    private func detectLanguage(from text: String) -> Language? {
        recognizer.reset()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        // NLLanguage rawValue is BCP-47 code like "en", "ru", "zh-Hans"
        let code = dominant.rawValue
        // Try direct match first
        if let lang = LanguageList.find(byCode: code) {
            return lang
        }
        // Try base language (e.g. "zh-Hans" -> "zh")
        let base = code.components(separatedBy: "-").first ?? code
        return LanguageList.find(byCode: base)
    }

    /// Perform translation with streaming
    func translate() async {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard let selectedId = settingsViewModel.selectedProviderId else {
            error = NSLocalizedString("error.no_provider_selected", comment: "No provider selected")
            return
        }

        // Re-setup providers in case config changed
        for config in settingsViewModel.providerConfigs where config.isEnabled {
            translationService.setupProvider(from: config)
        }

        isTranslating = true
        error = nil
        translatedText = ""

        // Use detected language when Auto Detect is selected
        let effectiveSource = (sourceLanguage.code == "auto")
            ? (detectedLanguage ?? sourceLanguage)
            : sourceLanguage

        let stream = translationService.translateStream(
            text: text,
            from: effectiveSource,
            to: targetLanguage,
            using: selectedId
        )

        var fullText = ""
        do {
            for try await chunk in stream {
                fullText += chunk
                translatedText = fullText
                await Task.yield() // Let SwiftUI re-render between chunks
            }

            // Post-process: extract detected language tag if present
            let (cleanedText, detectedLang) = LanguageDetectionHelper.extractDetectedLanguage(from: fullText)
            translatedText = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)

            if sourceLanguage.code == "auto" {
                if let detectedName = detectedLang {
                    detectedLanguage = Language(code: "auto", name: detectedName, localizedName: detectedName, flag: "✨")
                }
            } else {
                detectedLanguage = nil
            }

            AppLogger.shared.success("Translation",
                "Stream complete",
                details: "Result: \(translatedText.prefix(200))\(translatedText.count > 200 ? "..." : "")")
        } catch {
            self.error = error.localizedDescription
            AppLogger.shared.error("Translation",
                "Stream error",
                details: error.localizedDescription)
        }

        isTranslating = false
        translationService.isTranslating = false
    }

    /// Swap source and target languages and texts
    func swapLanguages() {
        if sourceLanguage.code == "auto" {
            // When Auto Detect: use detected language as new target
            guard let detected = detectedLanguage else { return }
            targetLanguage = detected
            // Keep sourceLanguage as auto — it will re-detect from new text
        } else {
            let tempLang = sourceLanguage
            sourceLanguage = targetLanguage
            targetLanguage = tempLang
        }

        let tempText = sourceText
        sourceText = translatedText
        translatedText = tempText

        saveLanguagePreferences()
    }

    /// Copy translated text to clipboard
    func copyTranslation() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translatedText, forType: .string)
    }

    /// Clear all text
    func clearAll() {
        sourceText = ""
        translatedText = ""
        error = nil
    }

    /// Save language preferences to UserDefaults
    func saveLanguagePreferences() {
        UserDefaults.standard.set(sourceLanguage.code, forKey: Constants.UserDefaultsKeys.sourceLanguageCode)
        UserDefaults.standard.set(targetLanguage.code, forKey: Constants.UserDefaultsKeys.targetLanguageCode)
    }

    private func restoreLanguagePreferences() {
        if let code = UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.sourceLanguageCode) {
            if code == "auto" {
                sourceLanguage = .autoDetect
            } else if let lang = LanguageList.find(byCode: code) {
                sourceLanguage = lang
            }
        }
        if let code = UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.targetLanguageCode),
           let lang = LanguageList.find(byCode: code) {
            targetLanguage = lang
        }
    }
}
