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
    private var cancellables = Set<AnyCancellable>()

    init() {
        loadConfigs()
    }

    /// Observe ModelCatalog changes to keep local provider auth in sync
    func observeModelCatalog(_ catalog: ModelCatalog) {
        cancellables.removeAll()
        catalog.$activeModelId
            .sink { [weak self] activeId in
                self?.syncLocalProviderAuth(hasActiveModel: activeId != nil)
            }
            .store(in: &cancellables)
    }

    /// Update isAuthenticated for all .local providers based on model availability
    func syncLocalProviderAuth(hasActiveModel: Bool) {
        var changed = false
        for i in providerConfigs.indices where providerConfigs[i].type == .local {
            if providerConfigs[i].isAuthenticated != hasActiveModel {
                providerConfigs[i].isAuthenticated = hasActiveModel
                changed = true
            }
        }
        if changed { saveConfigs() }
    }

    /// Fetch available models for a provider from its API
    func fetchModels(forProvider id: String) {
        guard let config = providerConfigs.first(where: { $0.id == id }) else { return }

        let oauthTokens = keychain.getOAuthTokens(forProvider: id)
        let apiKey = keychain.getAPIKey(forProvider: id)

        // Providers with dynamic model lists need auth first
        switch config.type {
        case .openai, .anthropic:
            guard oauthTokens != nil || apiKey != nil else {
                // Not authenticated yet — no models to show
                fetchedModels[id] = []
                return
            }
        case .gemini:
            // Gemini supports OAuth — try dynamic fetch if authenticated, otherwise use hardcoded
            guard oauthTokens != nil || apiKey != nil else {
                fetchedModels[id] = config.type.availableModels
                return
            }
        case .qwen, .local:
            // These use hardcoded lists — no API needed
            fetchedModels[id] = config.type.availableModels
            return
        }

        Task {
            switch config.type {
            case .anthropic:
                if let tokens = oauthTokens {
                    let models = await ModelService.shared.fetchAnthropicModels(
                        token: tokens.accessToken, providerId: config.id)
                    fetchedModels[id] = models
                    AppLogger.info("Models", "Loaded \(models.count) Anthropic models")
                }
            case .openai:
                let models = await ModelService.shared.fetchOpenAIModels(
                    token: oauthTokens?.accessToken,
                    apiKey: apiKey,
                    baseURL: config.baseURL
                )
                fetchedModels[id] = models
                AppLogger.info("Models", "Loaded \(models.count) OpenAI models")
            case .qwen, .local:
                break // handled above with hardcoded lists
            case .gemini:
                if let tokens = oauthTokens {
                    let models = await ModelService.shared.fetchGeminiModels(
                        token: tokens.accessToken, providerId: config.id)
                    fetchedModels[id] = models
                    AppLogger.info("Models", "Loaded \(models.count) Gemini models")
                } else if let apiKey = apiKey {
                    let models = await ModelService.shared.fetchGeminiModels(
                        token: apiKey, providerId: config.id)
                    fetchedModels[id] = models
                    AppLogger.info("Models", "Loaded \(models.count) Gemini models")
                }
            }
        }
    }

    /// Get models for a provider (fetched dynamically or hardcoded for some providers)
    func modelsForProvider(_ id: String) -> [(id: String, name: String)] {
        if let fetched = fetchedModels[id] {
            return fetched
        }
        // Only use hardcoded for providers without dynamic model API
        guard let config = providerConfigs.first(where: { $0.id == id }) else { return [] }
        switch config.type {
        case .qwen, .gemini, .local:
            return config.type.availableModels
        case .openai, .anthropic:
            // Dynamic models — empty until authenticated and fetched
            return []
        }
    }

    // MARK: - Provider Management

    /// Add a new provider configuration
    func addProvider(type: ProviderType) {
        var config = ProviderConfig(type: type)

        if type == .local {
            // Local provider auth = model is selected
            config.isAuthenticated = UserDefaults.standard.string(forKey: "localModelActiveId") != nil
        } else {
            config.isAuthenticated = false
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
                success = await oauthService.startQwenOAuth(providerId: id)
                authUserCode = oauthService.userCode
            case .anthropic:
                success = await oauthService.startAnthropicOAuth(providerId: id)
            case .openai:
                success = await oauthService.startOpenAIOAuth(providerId: id)
            case .gemini:
                success = await oauthService.startGeminiOAuth(providerId: id)
            case .local:
                // No auth needed — model management handled separately
                break
            }

            if success {
                if let index = providerConfigs.firstIndex(where: { $0.id == id }) {
                    providerConfigs[index].isAuthenticated = true
                    providerConfigs[index].authMethod = .oauth
                    saveConfigs()
                    // Fetch dynamic models now that we have credentials
                    fetchModels(forProvider: id)
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
                // Fetch dynamic models now that we have credentials
                fetchModels(forProvider: id)
            }
        } catch {
            print("Failed to save API key: \(error)")
        }
    }

    /// Mark provider as disconnected (called when token refresh fails)
    func handleTokenExpired(providerId: String) {
        keychain.deleteCredentials(forProvider: providerId)
        if let idx = providerConfigs.firstIndex(where: { $0.id == providerId }) {
            providerConfigs[idx].isAuthenticated = false
            saveConfigs()
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

            // Check auth status from Keychain / local model state
            for i in providerConfigs.indices {
                let id = providerConfigs[i].id
                if providerConfigs[i].type == .local {
                    // Local provider is "authenticated" when a model is downloaded and selected
                    let hasActiveModel = UserDefaults.standard.string(forKey: "localModelActiveId") != nil
                    providerConfigs[i].isAuthenticated = hasActiveModel
                } else {
                    let hasOAuth = keychain.getOAuthTokens(forProvider: id) != nil
                    let hasAPIKey = keychain.getAPIKey(forProvider: id) != nil
                    providerConfigs[i].isAuthenticated = hasOAuth || hasAPIKey
                }
            }
        }
        selectedProviderId = UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.selectedProviderId)
    }
}
