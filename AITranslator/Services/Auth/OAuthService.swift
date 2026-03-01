import Foundation
import AppKit
import CommonCrypto

/// Manages OAuth browser authentication flows for AI providers.
/// Implements Device Code Flow for Qwen (RFC 8628) and OAuth2 PKCE for Anthropic.
@MainActor
final class OAuthService: ObservableObject {
    static let shared = OAuthService()
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

    // MARK: - Anthropic/Claude OAuth (Authorization Code + PKCE via localhost)

    /// Claude Code OAuth constants (from Claude Code CLI source)
    private let claudeAuthURL = "https://claude.ai/oauth/authorize"
    private let claudeTokenURL = "https://platform.claude.com/v1/oauth/token"
    private let claudeClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let claudeScopes = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers"

    /// Start Anthropic OAuth using the same flow as Claude Code CLI:
    /// 1. Start localhost HTTP server on random port
    /// 2. Open browser to claude.ai/oauth/authorize with PKCE
    /// 3. Wait for callback on localhost with auth code
    /// 4. Exchange code for tokens
    func startAnthropicOAuth(providerId: String) async -> Bool {
        isAuthenticating = true
        authError = nil

        do {
            // Step 1: Generate PKCE pair and state
            let codeVerifier = generateCodeVerifier()
            let codeChallenge = generateCodeChallenge(from: codeVerifier)
            let state = generateCodeVerifier() // Random state

            // Step 2: Start localhost HTTP server and get port
            let callbackServer = LocalCallbackServer()
            let port = try await callbackServer.start()
            let redirectURI = "http://localhost:\(port)/callback"

            // Step 3: Build auth URL and open browser
            var components = URLComponents(string: claudeAuthURL)!
            components.queryItems = [
                URLQueryItem(name: "code", value: "true"),
                URLQueryItem(name: "client_id", value: claudeClientId),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "scope", value: claudeScopes),
                URLQueryItem(name: "code_challenge", value: codeChallenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: state)
            ]

            if let url = components.url {
                NSWorkspace.shared.open(url)
            }

            // Step 4: Wait for callback (blocks until browser redirects back)
            let callbackResult = try await callbackServer.waitForCallback(timeoutSeconds: 120)
            callbackServer.stop()

            // Step 5: Verify state
            guard callbackResult.state == state else {
                authError = "OAuth state mismatch"
                isAuthenticating = false
                return false
            }

            guard let code = callbackResult.code else {
                authError = callbackResult.error ?? "No authorization code received"
                isAuthenticating = false
                return false
            }

            // Step 6: Exchange code for tokens
            let success = await exchangeAnthropicCode(
                code: code,
                codeVerifier: codeVerifier,
                redirectURI: redirectURI,
                state: state,
                providerId: providerId
            )
            return success

        } catch {
            authError = error.localizedDescription
            isAuthenticating = false
            return false
        }
    }

    /// Handle OAuth callback URL (legacy - kept for compatibility but not used with localhost flow)
    func handleCallback(url: URL, providerId: String) async -> Bool {
        return false
    }

    /// Exchange authorization code for tokens using Claude's token endpoint
    /// Body format: JSON with {grant_type, code, redirect_uri, client_id, code_verifier, state}
    /// Verified via curl against platform.claude.com/v1/oauth/token
    private func exchangeAnthropicCode(
        code: String,
        codeVerifier: String,
        redirectURI: String,
        state: String,
        providerId: String
    ) async -> Bool {
        guard let url = URL(string: claudeTokenURL) else {
            authError = "Invalid token URL"
            isAuthenticating = false
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": claudeClientId,
            "code_verifier": codeVerifier,
            "state": state
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                authError = "Invalid response"
                isAuthenticating = false
                return false
            }

            guard httpResponse.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown"
                authError = "Token exchange failed (\(httpResponse.statusCode)): \(errorBody)"
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

    // MARK: - OpenAI OAuth (Authorization Code + PKCE via localhost, Codex CLI flow)

    /// OpenAI Codex CLI OAuth constants
    private let openAIAuthURL = "https://auth.openai.com/oauth/authorize"
    private let openAITokenURL = "https://auth.openai.com/oauth/token"
    private let openAIClientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let openAIScopes = "openid profile email offline_access"
    private let openAICallbackPort: UInt16 = 1455

    /// Start OpenAI OAuth using the same flow as Codex CLI:
    /// 1. Start localhost HTTP server on port 1455
    /// 2. Open browser to auth.openai.com/oauth/authorize with PKCE + Codex params
    /// 3. Wait for callback with auth code
    /// 4. Exchange code for tokens
    func startOpenAIOAuth(providerId: String) async -> Bool {
        isAuthenticating = true
        authError = nil

        do {
            // Step 1: Generate PKCE pair and state
            let codeVerifier = generateCodeVerifier()
            let codeChallenge = generateCodeChallenge(from: codeVerifier)
            let state = generateCodeVerifier()

            // Step 2: Start localhost HTTP server on fixed port 1455 (Codex CLI convention)
            let callbackServer = LocalCallbackServer()
            let port = try await callbackServer.start(preferredPort: openAICallbackPort)
            let redirectURI = "http://localhost:\(port)/auth/callback"

            // Step 3: Build auth URL with Codex CLI special parameters
            var components = URLComponents(string: openAIAuthURL)!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: openAIClientId),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "scope", value: openAIScopes),
                URLQueryItem(name: "code_challenge", value: codeChallenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
                URLQueryItem(name: "originator", value: "codex_cli_rs")
            ]

            AppLogger.info("OAuth", "Opening OpenAI OAuth in browser",
                details: "URL: \(components.url?.absoluteString ?? "nil")")

            if let url = components.url {
                NSWorkspace.shared.open(url)
            }

            // Step 4: Wait for callback
            let callbackResult = try await callbackServer.waitForCallback(timeoutSeconds: 120)
            callbackServer.stop()

            // Step 5: Verify state
            guard callbackResult.state == state else {
                throw AIProviderError.apiError("OAuth state mismatch")
            }

            guard let code = callbackResult.code else {
                throw AIProviderError.apiError("No authorization code received")
            }

            AppLogger.success("OAuth", "OpenAI authorization code received")

            // Step 6: Exchange code for tokens
            let success = await exchangeOpenAICode(
                code: code,
                codeVerifier: codeVerifier,
                redirectURI: redirectURI,
                providerId: providerId
            )
            return success

        } catch {
            authError = error.localizedDescription
            AppLogger.error("OAuth", "OpenAI OAuth failed", details: error.localizedDescription)
            isAuthenticating = false
            return false
        }
    }

    /// Exchange OpenAI authorization code for tokens
    private func exchangeOpenAICode(
        code: String,
        codeVerifier: String,
        redirectURI: String,
        providerId: String
    ) async -> Bool {
        guard let url = URL(string: openAITokenURL) else {
            authError = "Invalid token URL"
            isAuthenticating = false
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": openAIClientId,
            "code_verifier": codeVerifier
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            AppLogger.request("OAuth", "POST \(openAITokenURL)", details: "Exchanging code for OpenAI tokens")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                authError = "Invalid response"
                isAuthenticating = false
                return false
            }

            let responseBody = String(data: data, encoding: .utf8) ?? ""
            AppLogger.response("OAuth", "OpenAI token response (\(httpResponse.statusCode))", details: responseBody)

            guard httpResponse.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else {
                authError = "Token exchange failed: \(responseBody)"
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
            AppLogger.success("OAuth", "OpenAI OAuth complete — tokens saved")
            isAuthenticating = false
            return true

        } catch {
            authError = "Token exchange failed: \(error.localizedDescription)"
            isAuthenticating = false
            return false
        }
    }

    // MARK: - API Key (Fallback)

    func saveAPIKey(_ key: String, forProvider providerId: String) throws {
        try keychain.saveAPIKey(key, forProvider: providerId)
    }

    // MARK: - Token Refresh

    /// Refresh an expired Qwen OAuth token using the stored refresh_token
    func refreshQwenToken(forProvider providerId: String) async throws -> OAuthTokens {
        guard let tokens = keychain.getOAuthTokens(forProvider: providerId),
              let refreshToken = tokens.refreshToken else {
            throw AIProviderError.notAuthenticated
        }

        guard let url = URL(string: qwenTokenEndpoint) else {
            throw AIProviderError.apiError("Invalid token URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Qwen requires form-urlencoded, not JSON
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: qwenClientId),
            URLQueryItem(name: "refresh_token", value: refreshToken)
        ]
        request.httpBody = components.query?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown"
            throw AIProviderError.apiError("Token refresh failed: \(errorBody)")
        }

        let newTokens = OAuthTokens(
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String ?? refreshToken,
            expiresAt: (json["expires_in"] as? TimeInterval).map { Date().addingTimeInterval($0) },
            tokenType: json["token_type"] as? String ?? "Bearer",
            resourceURL: json["resource_url"] as? String ?? tokens.resourceURL
        )

        try keychain.saveOAuthTokens(newTokens, forProvider: providerId)
        print("[OAuth] Qwen token refreshed successfully")
        return newTokens
    }

    /// Refresh an expired Claude OAuth token using the stored refresh_token
    func refreshClaudeToken(forProvider providerId: String) async throws -> OAuthTokens {
        guard let tokens = keychain.getOAuthTokens(forProvider: providerId),
              let refreshToken = tokens.refreshToken else {
            throw AIProviderError.notAuthenticated
        }

        guard let url = URL(string: claudeTokenURL) else {
            throw AIProviderError.apiError("Invalid token URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": claudeClientId
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown"
            throw AIProviderError.apiError("Claude token refresh failed: \(errorBody)")
        }

        let newTokens = OAuthTokens(
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String ?? refreshToken,
            expiresAt: (json["expires_in"] as? TimeInterval).map { Date().addingTimeInterval($0) },
            tokenType: json["token_type"] as? String ?? "Bearer"
        )

        try keychain.saveOAuthTokens(newTokens, forProvider: providerId)
        print("[OAuth] Claude token refreshed successfully")
        return newTokens
    }

    /// Refresh an expired OpenAI OAuth token using the stored refresh_token
    func refreshOpenAIToken(forProvider providerId: String) async throws -> OAuthTokens {
        guard let tokens = keychain.getOAuthTokens(forProvider: providerId),
              let refreshToken = tokens.refreshToken else {
            throw AIProviderError.notAuthenticated
        }

        guard let url = URL(string: openAITokenURL) else {
            throw AIProviderError.apiError("Invalid token URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": openAIClientId
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown"
            throw AIProviderError.apiError("OpenAI token refresh failed: \(errorBody)")
        }

        let newTokens = OAuthTokens(
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String ?? refreshToken,
            expiresAt: (json["expires_in"] as? TimeInterval).map { Date().addingTimeInterval($0) },
            tokenType: json["token_type"] as? String ?? "Bearer"
        )

        try keychain.saveOAuthTokens(newTokens, forProvider: providerId)
        AppLogger.success("OAuth", "OpenAI token refreshed successfully")
        return newTokens
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
    case serverStartFailed(String)
    case timeout
    case noDataReceived

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
        case .serverStartFailed(let reason):
            return "Failed to start callback server: \(reason)"
        case .timeout:
            return "Authentication timed out. Please try again."
        case .noDataReceived:
            return "No data received from browser callback"
        }
    }
}
