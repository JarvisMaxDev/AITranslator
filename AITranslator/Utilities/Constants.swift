import Foundation

/// App-wide constants
enum Constants {
    /// Default double-press interval for global hotkey (seconds)
    static let doublePressInterval: TimeInterval = 0.4

    /// Maximum text length for translation
    static let maxTextLength = 10000

    /// UserDefaults keys
    enum UserDefaultsKeys {
        static let providerConfigs = "providerConfigs"
        static let selectedProviderId = "selectedProviderId"
        static let sourceLanguageCode = "sourceLanguageCode"
        static let targetLanguageCode = "targetLanguageCode"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let fontSize = "fontSize"
    }
}
