import SwiftUI
import Combine

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

    private let translationService = TranslationService()
    private let settingsViewModel: SettingsViewModel
    private var cancellables = Set<AnyCancellable>()

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

        // Restore saved language preferences
        restoreLanguagePreferences()
    }

    /// Perform translation
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

        let response = await translationService.translate(
            text: text,
            from: sourceLanguage,
            to: targetLanguage,
            using: selectedId
        )

        isTranslating = false

        if let response {
            translatedText = response.translatedText
        } else {
            error = translationService.error ?? NSLocalizedString("error.translation_failed", comment: "Translation failed")
        }
    }

    /// Swap source and target languages and texts
    func swapLanguages() {
        guard sourceLanguage.code != "auto" else { return }

        let tempLang = sourceLanguage
        sourceLanguage = targetLanguage
        targetLanguage = tempLang

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
