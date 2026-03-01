import Foundation

/// Represents a language for translation
struct Language: Identifiable, Hashable, Codable {
    let code: String
    let name: String
    let localizedName: String
    let flag: String

    var id: String { code }

    /// Special "Auto Detect" language for source
    static let autoDetect = Language(
        code: "auto",
        name: "Auto Detect",
        localizedName: NSLocalizedString("language.auto_detect", comment: "Auto Detect"),
        flag: "🌐"
    )
}

/// Predefined list of supported languages
struct LanguageList {
    static let all: [Language] = [
        Language(code: "en", name: "English", localizedName: "English", flag: "🇬🇧"),
        Language(code: "ru", name: "Russian", localizedName: "Русский", flag: "🇷🇺"),
        Language(code: "de", name: "German", localizedName: "Deutsch", flag: "🇩🇪"),
        Language(code: "fr", name: "French", localizedName: "Français", flag: "🇫🇷"),
        Language(code: "es", name: "Spanish", localizedName: "Español", flag: "🇪🇸"),
        Language(code: "it", name: "Italian", localizedName: "Italiano", flag: "🇮🇹"),
        Language(code: "pt", name: "Portuguese", localizedName: "Português", flag: "🇵🇹"),
        Language(code: "zh", name: "Chinese", localizedName: "中文", flag: "🇨🇳"),
        Language(code: "ja", name: "Japanese", localizedName: "日本語", flag: "🇯🇵"),
        Language(code: "ko", name: "Korean", localizedName: "한국어", flag: "🇰🇷"),
        Language(code: "ar", name: "Arabic", localizedName: "العربية", flag: "🇸🇦"),
        Language(code: "hi", name: "Hindi", localizedName: "हिन्दी", flag: "🇮🇳"),
        Language(code: "tr", name: "Turkish", localizedName: "Türkçe", flag: "🇹🇷"),
        Language(code: "pl", name: "Polish", localizedName: "Polski", flag: "🇵🇱"),
        Language(code: "nl", name: "Dutch", localizedName: "Nederlands", flag: "🇳🇱"),
        Language(code: "sv", name: "Swedish", localizedName: "Svenska", flag: "🇸🇪"),
        Language(code: "da", name: "Danish", localizedName: "Dansk", flag: "🇩🇰"),
        Language(code: "no", name: "Norwegian", localizedName: "Norsk", flag: "🇳🇴"),
        Language(code: "fi", name: "Finnish", localizedName: "Suomi", flag: "🇫🇮"),
        Language(code: "uk", name: "Ukrainian", localizedName: "Українська", flag: "🇺🇦"),
        Language(code: "cs", name: "Czech", localizedName: "Čeština", flag: "🇨🇿"),
        Language(code: "el", name: "Greek", localizedName: "Ελληνικά", flag: "🇬🇷"),
        Language(code: "he", name: "Hebrew", localizedName: "עברית", flag: "🇮🇱"),
        Language(code: "th", name: "Thai", localizedName: "ไทย", flag: "🇹🇭"),
        Language(code: "vi", name: "Vietnamese", localizedName: "Tiếng Việt", flag: "🇻🇳"),
        Language(code: "id", name: "Indonesian", localizedName: "Bahasa Indonesia", flag: "🇮🇩"),
        Language(code: "ro", name: "Romanian", localizedName: "Română", flag: "🇷🇴"),
        Language(code: "hu", name: "Hungarian", localizedName: "Magyar", flag: "🇭🇺"),
        Language(code: "bg", name: "Bulgarian", localizedName: "Български", flag: "🇧🇬"),
        Language(code: "sk", name: "Slovak", localizedName: "Slovenčina", flag: "🇸🇰"),
    ]

    /// Find language by code
    static func find(byCode code: String) -> Language? {
        all.first { $0.code == code }
    }
}
