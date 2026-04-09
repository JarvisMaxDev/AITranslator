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

    let oauthService = OAuthService.shared
    private let keychain = KeychainService.shared
    private var cancellables = Set<AnyCancellable>()
    /// Set via observeModelCatalog() so the .local provider's dropdown can show
    /// downloaded models from the catalog instead of the hardcoded stub.
    private weak var modelCatalog: ModelCatalog?
    /// In-flight OAuth Task. Stored so cancelAuth() can actually cancel it
    /// (Qwen polling Task.sleep + Anthropic/OpenAI/Gemini waitForCallback both
    /// react to Task cancellation; the localhost socket is also closed via
    /// OAuthService.cancelAuth which unblocks the underlying accept()).
    private var authTask: Task<Void, Never>?

    init() {
        loadConfigs()

        // Bind OAuth user code from the singleton so Qwen device code becomes
        // visible WHILE the flow is in progress. Reading it after `await` is too
        // late — the value is cleared by the time startQwenOAuth returns.
        oauthService.$userCode
            .receive(on: RunLoop.main)
            .assign(to: &$authUserCode)
    }

    /// Observe ModelCatalog changes to keep local provider auth in sync and
    /// to refresh the local provider's model dropdown when downloads complete.
    func observeModelCatalog(_ catalog: ModelCatalog) {
        cancellables.removeAll()
        modelCatalog = catalog

        catalog.$activeModelId
            .sink { [weak self] activeId in
                self?.syncLocalProviderAuth(hasActiveModel: activeId != nil)
                // Refresh local providers' fetched model lists so the dropdown
                // updates when the user activates/deactivates a model.
                self?.refreshLocalProvidersModels()
            }
            .store(in: &cancellables)

        catalog.$modelStates
            .sink { [weak self] _ in
                // A download finished or a model was removed → rebuild the local
                // provider's dropdown so it reflects on-disk reality.
                self?.refreshLocalProvidersModels()
            }
            .store(in: &cancellables)
    }

    /// Rebuild the cached model list for every .local provider config.
    private func refreshLocalProvidersModels() {
        for config in providerConfigs where config.type == .local {
            fetchModels(forProvider: config.id)
        }
    }

    /// Activate the given local model id in the catalog (called from Settings
    /// when the user changes the .local provider's dropdown selection).
    func selectLocalModel(id: String) {
        guard let catalog = modelCatalog,
              let model = catalog.models.first(where: { $0.id == id }) else { return }
        catalog.selectModel(model)
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
        case .qwen:
            // Hardcoded list — no API needed
            fetchedModels[id] = config.type.availableModels
            return
        case .local:
            // Show DOWNLOADED models from ModelCatalog (not the hardcoded
            // single-entry stub from ProviderType.availableModels).
            if let catalog = modelCatalog {
                let downloaded = catalog.models.filter { model in
                    let state = catalog.modelStates[model.id]
                    return state == .downloaded || state == .active
                }
                fetchedModels[id] = downloaded.map { (id: $0.id, name: $0.name) }
            } else {
                fetchedModels[id] = []
            }
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
        case .qwen, .gemini:
            return config.type.availableModels
        case .local:
            // Build downloaded list on demand if observeModelCatalog hasn't run yet
            if let catalog = modelCatalog {
                let downloaded = catalog.models.filter { model in
                    let state = catalog.modelStates[model.id]
                    return state == .downloaded || state == .active
                }
                return downloaded.map { (id: $0.id, name: $0.name) }
            }
            return []
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
        // Re-entrancy guard: do not spawn a second flow on top of an in-flight one.
        // Without this, mashing Connect would queue duplicate Tasks and (for OpenAI)
        // bind the fixed callback port 1455 twice → port collision crash.
        guard !isAuthenticating else { return }
        guard let config = providerConfigs.first(where: { $0.id == id }) else { return }

        isAuthenticating = true
        authError = nil
        authUserCode = nil

        authTask = Task { [weak self] in
            guard let self else { return }
            var success = false

            switch config.type {
            case .qwen:
                // userCode is delivered via Combine binding to $authUserCode
                // while the flow is running — see init().
                success = await self.oauthService.startQwenOAuth(providerId: id)
            case .anthropic:
                success = await self.oauthService.startAnthropicOAuth(providerId: id)
            case .openai:
                success = await self.oauthService.startOpenAIOAuth(providerId: id)
            case .gemini:
                success = await self.oauthService.startGeminiOAuth(providerId: id)
            case .local:
                // No auth needed — model management handled separately
                break
            }

            // If the user cancelled, stay quiet — no error toast, no model refetch.
            if Task.isCancelled {
                self.isAuthenticating = false
                self.authTask = nil
                return
            }

            if success {
                if let index = self.providerConfigs.firstIndex(where: { $0.id == id }) {
                    self.providerConfigs[index].isAuthenticated = true
                    self.providerConfigs[index].authMethod = .oauth
                    self.saveConfigs()
                    // Fetch dynamic models now that we have credentials
                    self.fetchModels(forProvider: id)
                }
            } else {
                self.authError = self.oauthService.authError
            }

            self.isAuthenticating = false
            self.authTask = nil
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
        // Cancel our enclosing Task first — this propagates to Qwen polling's
        // Task.sleep, which throws CancellationError immediately. Then close the
        // localhost socket so any waiting accept() also unwinds.
        authTask?.cancel()
        authTask = nil
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
