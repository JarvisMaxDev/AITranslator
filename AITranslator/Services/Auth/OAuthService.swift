import Foundation
import AppKit
import CommonCrypto

/// Manages OAuth browser authentication flows for AI providers.
/// Implements Device Code Flow for Qwen (RFC 8628) and OAuth2 PKCE for Anthropic.
@MainActor
final class OAuthService: ObservableObject {
    @Published var isAuthenticating = false
    @Published var authError: String?
    @Published var userCode: String?
    @Published var verificationURL: String?

    private let keychain = KeychainService.shared
    private var pollingTask: Task<Void, Never>?

    // MARK: - Qwen OAuth Constants (from QwenLM/qwen-code source)

    private let qwenBaseURL = "https://chat.qwen.ai"
    private let qwenDeviceCodeEndpoint = "https://chat.qwen.ai/api/v1/oauth2/device/code"
    private let qwenTokenEndpoint = "https://chat.qwen.ai/api/v1/oauth2/token"
    private let qwenClientId = "f0304373b74a44d2b584a3fb70ca9e56"
    private let qwenScope = "openid profile email model.completion"
    private let qwenGrantType = "urn:ietf:params:oauth:grant-type:device_code"

    // MARK: - Qwen Device Code OAuth (RFC 8628)

    /// Start Qwen OAuth using the device code flow.
    /// Identical to how qwen-code CLI authenticates.
    func startQwenOAuth(providerId: String) async -> Bool {
        isAuthenticating = true
        authError = nil
        userCode = nil
        verificationURL = nil

        do {
            // Step 1: Generate PKCE pair
            let codeVerifier = generateCodeVerifier()
            let codeChallenge = generateCodeChallenge(from: codeVerifier)

            // Step 2: Request device authorization
            let deviceAuth = try await requestDeviceAuthorization(
                codeChallenge: codeChallenge
            )

            // Step 3: Show user the code and open browser
            userCode = deviceAuth.userCode
            verificationURL = deviceAuth.verificationURIComplete

            if let url = URL(string: deviceAuth.verificationURIComplete) {
                NSWorkspace.shared.open(url)
            }

            // Step 4: Poll for token until user completes auth in browser
            let tokens = try await pollForToken(
                deviceCode: deviceAuth.deviceCode,
                codeVerifier: codeVerifier,
                expiresIn: deviceAuth.expiresIn
            )

            // Step 5: Save tokens to Keychain
            try keychain.saveOAuthTokens(tokens, forProvider: providerId)

            // Also cache to ~/.qwen/oauth_creds.json for compatibility with Qwen CLI
            cacheCredentialsToQwenDir(tokens)

            isAuthenticating = false
            userCode = nil
            verificationURL = nil
            return true
        } catch let existing as QwenExistingTokens {
            // Found existing Qwen CLI credentials during fallback
            let tokens = OAuthTokens(
                accessToken: existing.accessToken,
                refreshToken: existing.refreshToken,
                expiresAt: existing.expiresAt,
                tokenType: "Bearer"
            )
            do {
                try keychain.saveOAuthTokens(tokens, forProvider: providerId)
                isAuthenticating = false
                userCode = nil
                verificationURL = nil
                return true
            } catch {
                authError = "Failed to save tokens: \(error.localizedDescription)"
                isAuthenticating = false
                return false
            }
        } catch {
            authError = error.localizedDescription
            isAuthenticating = false
            userCode = nil
            verificationURL = nil
            return false
        }
    }

    // MARK: - Anthropic OAuth (OAuth2 PKCE)

    /// Start Anthropic OAuth using PKCE flow.
    /// Note: Anthropic restricts OAuth tokens to Claude Code only.
    /// API key is the recommended alternative.
    func startAnthropicOAuth(providerId: String) async -> Bool {
        isAuthenticating = true
        authError = nil

        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)
        let state = UUID().uuidString

        var components = URLComponents(string: "https://platform.claude.com/oauth/authorize")
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: "aitranslator"),
            URLQueryItem(name: "redirect_uri", value: "aitranslator://auth/callback"),
            URLQueryItem(name: "scope", value: "user:inference"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        if let url = components?.url {
            NSWorkspace.shared.open(url)
        } else {
            authError = "Failed to build Anthropic auth URL"
            isAuthenticating = false
            return false
        }

        UserDefaults.standard.set(codeVerifier, forKey: "anthropic_code_verifier_\(providerId)")
        UserDefaults.standard.set(state, forKey: "anthropic_state_\(providerId)")

        return true // Will complete asynchronously via URL callback
    }

    /// Handle OAuth callback URL from browser (for Anthropic PKCE flow)
    func handleCallback(url: URL, providerId: String) async -> Bool {
        guard url.scheme == "aitranslator",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            authError = "Invalid callback URL"
            isAuthenticating = false
            return false
        }

        let code = queryItems.first(where: { $0.name == "code" })?.value
        let state = queryItems.first(where: { $0.name == "state" })?.value
        let error = queryItems.first(where: { $0.name == "error" })?.value

        if let error {
            authError = "Authentication failed: \(error)"
            isAuthenticating = false
            return false
        }

        let savedState = UserDefaults.standard.string(forKey: "anthropic_state_\(providerId)")
        guard state == savedState else {
            authError = "OAuth state mismatch"
            isAuthenticating = false
            return false
        }

        guard let code else {
            authError = "No authorization code received"
            isAuthenticating = false
            return false
        }

        let codeVerifier = UserDefaults.standard.string(forKey: "anthropic_code_verifier_\(providerId)")

        return await exchangeAnthropicCode(
            code: code,
            codeVerifier: codeVerifier,
            providerId: providerId
        )
    }

    // MARK: - API Key (Fallback)

    func saveAPIKey(_ key: String, forProvider providerId: String) throws {
        try keychain.saveAPIKey(key, forProvider: providerId)
    }

    func disconnect(providerId: String) {
        keychain.deleteCredentials(forProvider: providerId)
        pollingTask?.cancel()
    }

    func cancelAuth() {
        pollingTask?.cancel()
        isAuthenticating = false
        userCode = nil
        verificationURL = nil
    }

    // MARK: - Qwen Device Code Implementation

    private struct DeviceAuthResponse {
        let deviceCode: String
        let userCode: String
        let verificationURI: String
        let verificationURIComplete: String
        let expiresIn: Int
    }

    /// POST to /api/v1/oauth2/device/code
    /// Content-Type: application/x-www-form-urlencoded
    private func requestDeviceAuthorization(codeChallenge: String) async throws -> DeviceAuthResponse {
        guard let url = URL(string: qwenDeviceCodeEndpoint) else {
            throw OAuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "x-request-id")

        let params = [
            "client_id": qwenClientId,
            "scope": qwenScope,
            "code_challenge": codeChallenge,
            "code_challenge_method": "S256"
        ]
        request.httpBody = urlEncode(params).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OAuthError.serverError("Device authorization failed (\(httpResponse.statusCode)): \(body)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String else {
            throw OAuthError.invalidResponse
        }

        return DeviceAuthResponse(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: json["verification_uri"] as? String ?? "\(qwenBaseURL)/authorize",
            verificationURIComplete: json["verification_uri_complete"] as? String
                ?? "\(qwenBaseURL)/authorize?user_code=\(userCode)&client=qwen-code",
            expiresIn: json["expires_in"] as? Int ?? 300
        )
    }

    /// Poll POST to /api/v1/oauth2/token every 2 seconds
    /// Content-Type: application/x-www-form-urlencoded
    private func pollForToken(
        deviceCode: String,
        codeVerifier: String,
        expiresIn: Int
    ) async throws -> OAuthTokens {
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        var pollInterval: UInt64 = 2_000_000_000 // 2 seconds in nanoseconds

        while Date() < deadline {
            try await Task.sleep(nanoseconds: pollInterval)

            if Task.isCancelled { throw OAuthError.cancelled }

            guard let url = URL(string: qwenTokenEndpoint) else {
                throw OAuthError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let params = [
                "grant_type": qwenGrantType,
                "client_id": qwenClientId,
                "device_code": deviceCode,
                "code_verifier": codeVerifier
            ]
            request.httpBody = urlEncode(params).data(using: .utf8)

            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse

            // Handle pending/slow_down responses (RFC 8628)
            if httpResponse?.statusCode == 400 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? String {
                    if error == "authorization_pending" {
                        continue // User hasn't approved yet
                    }
                    if error == "slow_down" {
                        pollInterval += 1_000_000_000 // Increase interval by 1 second
                        continue
                    }
                    // Other errors (expired_token, access_denied, etc.)
                    let description = json["error_description"] as? String ?? error
                    throw OAuthError.serverError(description)
                }
            }

            if httpResponse?.statusCode == 429 {
                pollInterval += 1_000_000_000
                continue
            }

            guard httpResponse?.statusCode == 200 else {
                continue // Retry on other errors
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String,
                  !accessToken.isEmpty else {
                continue // Response doesn't have a token yet
            }

            return OAuthTokens(
                accessToken: accessToken,
                refreshToken: json["refresh_token"] as? String,
                expiresAt: (json["expires_in"] as? TimeInterval).map { Date().addingTimeInterval($0) },
                tokenType: json["token_type"] as? String ?? "Bearer",
                resourceURL: json["resource_url"] as? String
            )
        }

        throw OAuthError.expired
    }

    // MARK: - Anthropic Token Exchange

    private func exchangeAnthropicCode(
        code: String,
        codeVerifier: String?,
        providerId: String
    ) async -> Bool {
        guard let url = URL(string: "https://platform.claude.com/oauth/token") else {
            authError = "Invalid token URL"
            isAuthenticating = false
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": "aitranslator://auth/callback",
            "client_id": "aitranslator"
        ]
        if let verifier = codeVerifier {
            body["code_verifier"] = verifier
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else {
                authError = "Failed to exchange authorization code"
                isAuthenticating = false
                return false
            }

            let tokens = OAuthTokens(
                accessToken: accessToken,
                refreshToken: json["refresh_token"] as? String,
                expiresAt: (json["expires_in"] as? TimeInterval).map { Date().addingTimeInterval($0) },
                tokenType: json["token_type"] as? String ?? "Bearer"
            )

            try keychain.saveOAuthTokens(tokens, forProvider: providerId)
            isAuthenticating = false
            return true
        } catch {
            authError = "Token exchange failed: \(error.localizedDescription)"
            isAuthenticating = false
            return false
        }
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return Data(hash)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// URL-encode a dictionary to x-www-form-urlencoded format
    private func urlEncode(_ params: [String: String]) -> String {
        params.map { key, value in
            let escapedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let escapedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(escapedKey)=\(escapedValue)"
        }.joined(separator: "&")
    }

    // MARK: - Import / Cache from Qwen CLI

    /// Try to import existing credentials from Qwen CLI (~/.qwen/oauth_creds.json)
    func importQwenCLICredentials(forProvider providerId: String) -> Bool {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            homeDir.appendingPathComponent(".qwen/oauth_creds.json"),
            homeDir.appendingPathComponent(".qwen/oauth.json")
        ]

        for path in paths {
            guard FileManager.default.fileExists(atPath: path.path),
                  let data = try? Data(contentsOf: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else {
                continue
            }

            let tokens = OAuthTokens(
                accessToken: accessToken,
                refreshToken: json["refresh_token"] as? String,
                expiresAt: (json["expiry_date"] as? TimeInterval).map { Date(timeIntervalSince1970: $0 / 1000.0) }
                    ?? (json["expires_at"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) },
                tokenType: json["token_type"] as? String ?? "Bearer",
                resourceURL: json["resource_url"] as? String
            )

            do {
                try keychain.saveOAuthTokens(tokens, forProvider: providerId)
                return true
            } catch {
                continue
            }
        }

        return false
    }

    /// Cache tokens to ~/.qwen/oauth_creds.json for compatibility with Qwen CLI
    private func cacheCredentialsToQwenDir(_ tokens: OAuthTokens) {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let qwenDir = homeDir.appendingPathComponent(".qwen")
        let credsPath = qwenDir.appendingPathComponent("oauth_creds.json")

        do {
            try FileManager.default.createDirectory(at: qwenDir, withIntermediateDirectories: true)

            var json: [String: Any] = [
                "access_token": tokens.accessToken,
                "token_type": tokens.tokenType ?? "Bearer"
            ]
            if let refreshToken = tokens.refreshToken {
                json["refresh_token"] = refreshToken
            }
            if let expiresAt = tokens.expiresAt {
                json["expiry_date"] = expiresAt.timeIntervalSince1970 * 1000 // milliseconds
            }

            let data = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
            try data.write(to: credsPath)
        } catch {
            // Non-critical — just log
            print("Failed to cache Qwen credentials: \(error)")
        }
    }
}

// MARK: - Error Types

struct QwenExistingTokens: Error {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
}

enum OAuthError: LocalizedError {
    case invalidURL
    case invalidResponse
    case serverError(String)
    case expired
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid OAuth URL"
        case .invalidResponse:
            return "Invalid response from auth server"
        case .serverError(let msg):
            return msg
        case .expired:
            return NSLocalizedString("error.auth_timeout",
                comment: "Authentication timed out. Please try again.")
        case .cancelled:
            return NSLocalizedString("error.auth_cancelled",
                comment: "Authentication cancelled")
        }
    }
}
