import Foundation
import Security

/// Credential storage: API keys in Keychain, OAuth tokens in file system
final class KeychainService {
    static let shared = KeychainService()
    private let servicePrefix = "com.aitranslator"

    /// Directory for storing OAuth credentials
    private var credentialsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aitranslator/credentials")
    }

    private init() {
        // Ensure credentials directory exists
        try? FileManager.default.createDirectory(
            at: credentialsDir,
            withIntermediateDirectories: true
        )
    }

    // MARK: - API Keys (Keychain)

    /// Save an API key for a provider
    func saveAPIKey(_ key: String, forProvider providerId: String) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(servicePrefix).apikey",
            kSecAttrAccount as String: providerId,
            kSecValueData as String: data
        ]

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

    // MARK: - OAuth Tokens (File-based to avoid Keychain prompts during development)

    /// File path for provider's OAuth tokens
    private func oauthFilePath(forProvider providerId: String) -> URL {
        credentialsDir.appendingPathComponent("\(providerId)_oauth.json")
    }

    /// Save OAuth tokens for a provider (to file, not Keychain)
    func saveOAuthTokens(_ tokens: OAuthTokens, forProvider providerId: String) throws {
        let data = try JSONEncoder().encode(tokens)
        try data.write(to: oauthFilePath(forProvider: providerId), options: [.atomic])

        // Set file permissions to owner-only (0600)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: oauthFilePath(forProvider: providerId).path
        )
    }

    /// Retrieve OAuth tokens for a provider (from file)
    func getOAuthTokens(forProvider providerId: String) -> OAuthTokens? {
        let path = oauthFilePath(forProvider: providerId)
        guard FileManager.default.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path) else {
            return nil
        }
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    /// Delete all credentials for a provider
    func deleteCredentials(forProvider providerId: String) {
        // Delete API key from Keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(servicePrefix).apikey",
            kSecAttrAccount as String: providerId
        ]
        SecItemDelete(query as CFDictionary)

        // Delete OAuth token file
        try? FileManager.default.removeItem(at: oauthFilePath(forProvider: providerId))

        // Also clean up old Keychain OAuth entry if it exists
        let oauthQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(servicePrefix).oauth",
            kSecAttrAccount as String: providerId
        ]
        SecItemDelete(oauthQuery as CFDictionary)
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
