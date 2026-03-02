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

    /// Stream translation text token by token
    func translateStream(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error>
}

/// Default streaming implementation: falls back to non-streaming translate()
extension AIProvider {
    func translateStream(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await self.translate(request)
                    continuation.yield(response.translatedText)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
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
