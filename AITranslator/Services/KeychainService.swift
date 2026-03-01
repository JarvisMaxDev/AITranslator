import Foundation
import Security

/// Secure credential storage using macOS Keychain
final class KeychainService {
    static let shared = KeychainService()
    private let servicePrefix = "com.aitranslator"

    private init() {}

    // MARK: - API Keys

    /// Save an API key for a provider
    func saveAPIKey(_ key: String, forProvider providerId: String) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(servicePrefix).apikey",
            kSecAttrAccount as String: providerId,
            kSecValueData as String: data
        ]

        // Delete existing item first
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Retrieve an API key for a provider
    func getAPIKey(forProvider providerId: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(servicePrefix).apikey",
            kSecAttrAccount as String: providerId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    // MARK: - OAuth Tokens

    /// Save OAuth tokens (access + refresh) for a provider
    func saveOAuthTokens(_ tokens: OAuthTokens, forProvider providerId: String) throws {
        let data = try JSONEncoder().encode(tokens)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(servicePrefix).oauth",
            kSecAttrAccount as String: providerId,
            kSecValueData as String: data
        ]

        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Retrieve OAuth tokens for a provider
    func getOAuthTokens(forProvider providerId: String) -> OAuthTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(servicePrefix).oauth",
            kSecAttrAccount as String: providerId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    /// Delete all credentials for a provider
    func deleteCredentials(forProvider providerId: String) {
        for service in ["\(servicePrefix).apikey", "\(servicePrefix).oauth"] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: providerId
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}

/// OAuth token storage model
struct OAuthTokens: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var tokenType: String?
    /// The API base URL to use with this token (from Qwen's `resource_url` field)
    var resourceURL: String?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }
}

/// Keychain-specific errors
enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)
    case notFound

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Keychain save failed with status: \(status)"
        case .notFound:
            return "Item not found in Keychain"
        }
    }
}
