import SwiftUI
import Combine

/// ViewModel for settings and provider management
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var providerConfigs: [ProviderConfig] = []
    @Published var selectedProviderId: String?
    @Published var isAuthenticating = false
    @Published var authUserCode: String?
    @Published var authError: String?
    /// Dynamically fetched models per provider ID
    @Published var fetchedModels: [String: [(id: String, name: String)]] = [:]

    let oauthService = OAuthService()
    private let keychain = KeychainService.shared

    init() {
        loadConfigs()
    }

    /// Fetch available models for a provider from its API
    func fetchModels(forProvider id: String) {
        guard let config = providerConfigs.first(where: { $0.id == id }) else { return }

        let oauthTokens = keychain.getOAuthTokens(forProvider: id)
        let apiKey = keychain.getAPIKey(forProvider: id)

        // Need at least one auth method, otherwise use hardcoded fallback
        guard oauthTokens != nil || apiKey != nil else {
            fetchedModels[id] = config.type.availableModels
            return
        }

        Task {
            switch config.type {
            case .anthropic:
                if let tokens = oauthTokens {
                    let models = await ModelService.shared.fetchAnthropicModels(token: tokens.accessToken)
                    if !models.isEmpty {
                        fetchedModels[id] = models
                    } else {
                        fetchedModels[id] = config.type.availableModels
                    }
                } else {
                    fetchedModels[id] = config.type.availableModels
                }
            case .openai:
                let models = await ModelService.shared.fetchOpenAIModels(
                    token: oauthTokens?.accessToken,
                    apiKey: apiKey,
                    baseURL: config.baseURL
                )
                if !models.isEmpty {
                    fetchedModels[id] = models
                } else {
                    fetchedModels[id] = config.type.availableModels
                }
            case .qwen, .gemini:
                // Use hardcoded model lists (no /v1/models API available)
                fetchedModels[id] = config.type.availableModels
            }
        }
    }

    /// Get models for a provider (fetched or fallback to hardcoded)
    func modelsForProvider(_ id: String) -> [(id: String, name: String)] {
        if let fetched = fetchedModels[id], !fetched.isEmpty {
            return fetched
        }
        guard let config = providerConfigs.first(where: { $0.id == id }) else { return [] }
        return config.type.availableModels
    }

    // MARK: - Provider Management

    /// Add a new provider configuration
    func addProvider(type: ProviderType) {
        var config = ProviderConfig(type: type)
        config.isAuthenticated = false

        // For Qwen, try importing existing CLI credentials automatically
        if type == .qwen && oauthService.importQwenCLICredentials(forProvider: config.id) {
            config.isAuthenticated = true
            config.authMethod = .oauth
        }

        providerConfigs.append(config)

        if selectedProviderId == nil {
            selectedProviderId = config.id
        }
        saveConfigs()
    }

    /// Remove a provider
    func removeProvider(id: String) {
        keychain.deleteCredentials(forProvider: id)
        providerConfigs.removeAll { $0.id == id }

        if selectedProviderId == id {
            selectedProviderId = providerConfigs.first?.id
        }
        saveConfigs()
    }

    /// Update provider config
    func updateProvider(_ config: ProviderConfig) {
        if let index = providerConfigs.firstIndex(where: { $0.id == config.id }) {
            providerConfigs[index] = config
            saveConfigs()
        }
    }

    /// Select active provider
    func selectProvider(id: String) {
        selectedProviderId = id
        UserDefaults.standard.set(id, forKey: Constants.UserDefaultsKeys.selectedProviderId)
    }

    // MARK: - Authentication

    /// Start OAuth flow for a provider
    func startOAuth(forProvider id: String) {
        guard let config = providerConfigs.first(where: { $0.id == id }) else { return }

        isAuthenticating = true
        authError = nil
        authUserCode = nil

        Task {
            var success = false

            switch config.type {
            case .qwen:
                // Try importing existing Qwen CLI credentials first
                if oauthService.importQwenCLICredentials(forProvider: id) {
                    success = true
                } else {
                    success = await oauthService.startQwenOAuth(providerId: id)
                    authUserCode = oauthService.userCode
                }
            case .anthropic:
                success = await oauthService.startAnthropicOAuth(providerId: id)
            case .openai:
                success = await oauthService.startOpenAIOAuth(providerId: id)
            case .gemini:
                // API key only — no OAuth flow needed
                break
            }

            if success {
                if let index = providerConfigs.firstIndex(where: { $0.id == id }) {
                    providerConfigs[index].isAuthenticated = true
                    providerConfigs[index].authMethod = .oauth
                    saveConfigs()
                }
            } else {
                authError = oauthService.authError
            }

            isAuthenticating = false
            authUserCode = nil
        }
    }

    /// Save API key for a provider (fallback auth)
    func saveAPIKey(_ key: String, forProvider id: String) {
        do {
            try oauthService.saveAPIKey(key, forProvider: id)
            if let index = providerConfigs.firstIndex(where: { $0.id == id }) {
                providerConfigs[index].isAuthenticated = true
                providerConfigs[index].authMethod = .apiKey
                saveConfigs()
            }
        } catch {
            print("Failed to save API key: \(error)")
        }
    }

    /// Disconnect a provider
    func disconnectProvider(id: String) {
        oauthService.disconnect(providerId: id)
        if let index = providerConfigs.firstIndex(where: { $0.id == id }) {
            providerConfigs[index].isAuthenticated = false
            saveConfigs()
        }
    }

    /// Handle OAuth callback (for Anthropic PKCE flow)
    func handleOAuthCallback(url: URL) async {
        // Find the provider that's being authenticated
        guard let pendingId = providerConfigs.first(where: { !$0.isAuthenticated && $0.type == .anthropic })?.id else {
            return
        }

        let success = await oauthService.handleCallback(url: url, providerId: pendingId)
        if success {
            if let index = providerConfigs.firstIndex(where: { $0.id == pendingId }) {
                providerConfigs[index].isAuthenticated = true
                providerConfigs[index].authMethod = .oauth
                saveConfigs()
            }
        }
        isAuthenticating = false
    }

    /// Cancel ongoing authentication
    func cancelAuth() {
        oauthService.cancelAuth()
        isAuthenticating = false
        authUserCode = nil
        authError = nil
    }

    /// Get the active provider config
    var activeProvider: ProviderConfig? {
        if let id = selectedProviderId {
            return providerConfigs.first { $0.id == id }
        }
        return providerConfigs.first
    }

    // MARK: - Persistence

    private func saveConfigs() {
        if let data = try? JSONEncoder().encode(providerConfigs) {
            UserDefaults.standard.set(data, forKey: Constants.UserDefaultsKeys.providerConfigs)
        }
        if let id = selectedProviderId {
            UserDefaults.standard.set(id, forKey: Constants.UserDefaultsKeys.selectedProviderId)
        }
    }

    private func loadConfigs() {
        if let data = UserDefaults.standard.data(forKey: Constants.UserDefaultsKeys.providerConfigs),
           let configs = try? JSONDecoder().decode([ProviderConfig].self, from: data) {
            providerConfigs = configs

            // Check auth status from Keychain
            for i in providerConfigs.indices {
                let id = providerConfigs[i].id
                let hasOAuth = keychain.getOAuthTokens(forProvider: id) != nil
                let hasAPIKey = keychain.getAPIKey(forProvider: id) != nil
                providerConfigs[i].isAuthenticated = hasOAuth || hasAPIKey
            }
        }
        selectedProviderId = UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.selectedProviderId)
    }
}
