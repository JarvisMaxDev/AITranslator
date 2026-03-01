import Foundation

/// Protocol that all AI translation providers must conform to
protocol AIProvider {
    var id: String { get }
    var type: ProviderType { get }
    var isAuthenticated: Bool { get }

    /// Perform authentication (OAuth or API key)
    func authenticate() async throws

    /// Translate text from source to target language
    func translate(_ request: TranslationRequest) async throws -> TranslationResponse
}

/// Common errors for providers
enum AIProviderError: LocalizedError {
    case notAuthenticated
    case invalidResponse
    case apiError(String)
    case networkError(Error)
    case tokenExpired

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return NSLocalizedString("error.not_authenticated", comment: "Not authenticated")
        case .invalidResponse:
            return NSLocalizedString("error.invalid_response", comment: "Invalid response from provider")
        case .apiError(let message):
            return message
        case .networkError(let error):
            return error.localizedDescription
        case .tokenExpired:
            return NSLocalizedString("error.token_expired", comment: "Token expired, please re-authenticate")
        }
    }
}
