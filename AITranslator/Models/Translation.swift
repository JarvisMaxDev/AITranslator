import Foundation

/// Request for translation
struct TranslationRequest {
    let sourceText: String
    let sourceLanguage: Language
    let targetLanguage: Language
}

/// Response from translation
struct TranslationResponse {
    let translatedText: String
    let detectedLanguage: String?
}
