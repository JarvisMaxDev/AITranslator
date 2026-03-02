import SwiftUI
import Carbon.HIToolbox

struct SettingsView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    private enum Tab: String, CaseIterable {
        case general = "General"
        case providers = "AI Providers"
        
        var localizedStringKey: LocalizedStringKey {
            switch self {
            case .general: return "settings.general"
            case .providers: return "settings.providers"
            }
        }
    }

    @State private var selectedTab: Tab = .general
    
    // UI state
    @State private var showAddProvider = false
    @State private var apiKeyInput = ""
    @State private var showAPIKeyInput = false
    @State private var apiKeyTargetId: String?
    
    // Drafts for cancel/save
    @State private var draftConfigs: [ProviderConfig] = []
    @State private var draftSelectedProviderId: String? = nil
    @State private var hasChanges = false
    
    // Settings state
    @State private var hotkeyKeyCode: UInt32 = {
        let saved = UserDefaults.standard.integer(forKey: Constants.UserDefaultsKeys.hotkeyKeyCode)
        return saved > 0 ? UInt32(saved) : UInt32(kVK_ANSI_C)
    }()
    @State private var hotkeyModifiers: UInt32 = {
        let saved = UserDefaults.standard.integer(forKey: Constants.UserDefaultsKeys.hotkeyModifiers)
        return saved > 0 ? UInt32(saved) : UInt32(cmdKey | shiftKey)
    }()
    @State private var appLanguage: String = {
        let langs = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? []
        let first = langs.first ?? Locale.preferredLanguages.first ?? "en"
        return first.hasPrefix("ru") ? "ru" : "en"
    }()
    @State private var showRestartAlert = false

    var body: some View {
        VStack(spacing: 0) {
            // Custom Toolbar mimicking native layout but perfectly centered in the window
            HStack {
                Spacer()
                Picker("", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.localizedStringKey).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)
                Spacer()
            }
            .padding(.top, 16)
            .padding(.bottom, 16)
            
            // Content Area
            ZStack(alignment: .top) {
                switch selectedTab {
                case .general:
                    generalTab
                case .providers:
                    providersTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // Bottom Save/Cancel Bar
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Spacer()
                    Button(NSLocalizedString("action.cancel", comment: "Cancel")) {
                        draftConfigs = settingsViewModel.providerConfigs
                        draftSelectedProviderId = settingsViewModel.selectedProviderId
                        hasChanges = false
                        dismiss()
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    
                    Button(action: saveChanges) {
                        Text(NSLocalizedString("action.save", comment: "Save"))
                            .frame(minWidth: 60)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                    .disabled(!hasChanges)
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .padding(16)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(width: 650, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            draftConfigs = settingsViewModel.providerConfigs
            draftSelectedProviderId = settingsViewModel.selectedProviderId
            hasChanges = false
        }
        .onChange(of: settingsViewModel.providerConfigs) { newConfigs in
            if !hasChanges {
                draftConfigs = newConfigs
            }
        }
        .onChange(of: settingsViewModel.selectedProviderId) { newId in
            if !hasChanges {
                draftSelectedProviderId = newId
            }
        }
        .navigationTitle("")
        .sheet(isPresented: $showAddProvider) { addProviderSheet }
        .sheet(isPresented: $showAPIKeyInput) { apiKeyInputSheet }
        .alert(NSLocalizedString("settings.restart_title", comment: ""), isPresented: $showRestartAlert) {
            Button(NSLocalizedString("settings.restart_now", comment: "")) {
                let bundlePath = Bundle.main.bundlePath
                let script = "sleep 0.5; open \"\(bundlePath)\""
                let task = Process()
                task.launchPath = "/bin/sh"
                task.arguments = ["-c", script]
                try? task.run()
                NSApp.terminate(nil)
            }
            Button(NSLocalizedString("settings.restart_later", comment: ""), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("settings.restart_message", comment: ""))
        }
    }

    private func saveChanges() {
        for draft in draftConfigs {
            settingsViewModel.updateProvider(draft)
        }
        if let id = draftSelectedProviderId {
            settingsViewModel.selectProvider(id: id)
        }
        hasChanges = false
        dismiss()
    }

    // MARK: - General Tab

    private var generalTab: some View {
        VStack {
            GroupBox {
                VStack(spacing: 20) {
                    HStack(spacing: 24) {
                        Text(NSLocalizedString("settings.interface_language", comment: ""))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        
                        Picker("", selection: $appLanguage) {
                            Text("English").tag("en")
                            Text("Русский").tag("ru")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: appLanguage) { newValue in
                            UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
                            UserDefaults.standard.synchronize()
                            showRestartAlert = true
                        }
                    }

                    HStack(spacing: 24) {
                        Text(NSLocalizedString("settings.hotkey", comment: ""))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        
                        HotkeyRecorderView(
                            keyCode: $hotkeyKeyCode,
                            modifiers: $hotkeyModifiers
                        )
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(24)
            }
            .padding(32)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Providers Tab

    private var providersTab: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: { showAddProvider = true }) {
                    Label(NSLocalizedString("settings.add_provider", comment: "Add Provider"), systemImage: "plus")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)

            if draftConfigs.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(draftConfigs) { config in
                            providerRow(config)
                        }
                        
                        // Auth Error Display
                        if let error = settingsViewModel.authError {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                Spacer()
                                Button(action: { settingsViewModel.authError = nil }) {
                                    Image(systemName: "xmark.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.red.opacity(0.1)))
                        }

                        // Device Auth in Progress
                        if settingsViewModel.isAuthenticating {
                            authInProgressView
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    // MARK: - Provider Row

    private func providerRow(_ config: ProviderConfig) -> some View {
        let isActive = (draftSelectedProviderId == config.id)
        
        return HStack(alignment: .top, spacing: 16) {
            // Provider icon
            Image(systemName: config.type.iconSystemName)
                .font(.title)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))

            // Info and Actions
            VStack(alignment: .leading, spacing: 8) {
                // Top row: Title and Badge
                HStack(spacing: 8) {
                    Text(config.name)
                        .font(.headline)
                        .lineLimit(1)
                    
                    Spacer()
                }

                // Bottom row: Status, Picker, and Actions
                HStack(alignment: .center, spacing: 12) {
                    // Status
                    HStack(spacing: 6) {
                        Circle()
                            .fill(config.isAuthenticated ? .green : .orange)
                            .frame(width: 8, height: 8)
                        
                        Text(config.isAuthenticated
                             ? NSLocalizedString("settings.connected", comment: "Connected")
                             : NSLocalizedString("settings.not_connected", comment: "Not connected"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(1)
                        
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                        
                    // Model Picker
                    Picker("", selection: Binding(
                        get: { config.model },
                        set: { newModel in
                            if let idx = draftConfigs.firstIndex(where: { $0.id == config.id }) {
                                draftConfigs[idx].model = newModel
                                hasChanges = true
                            }
                        }
                    )) {
                        ForEach(settingsViewModel.modelsForProvider(config.id), id: \.id) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 180, alignment: .leading)
                    .onAppear {
                        settingsViewModel.fetchModels(forProvider: config.id)
                    }

                    Spacer()

                    // Actions
                    HStack(spacing: 8) {
                        if !config.isAuthenticated {
                            Button(NSLocalizedString("settings.connect", comment: "Connect")) {
                                settingsViewModel.startOAuth(forProvider: config.id)
                            }
                            .buttonStyle(.borderedProminent)
                            .fixedSize()
                            .disabled(settingsViewModel.isAuthenticating)

                            Button(NSLocalizedString("settings.api_key", comment: "API Key")) {
                                apiKeyTargetId = config.id
                                apiKeyInput = ""
                                showAPIKeyInput = true
                            }
                            .buttonStyle(.bordered)
                            .fixedSize()
                        } else {
                            if isActive {
                                Text(NSLocalizedString("settings.active", comment: "Active"))
                                    .font(.system(size: 11, weight: .bold))
                                    .textCase(.uppercase)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(.blue.opacity(0.15)))
                                    .foregroundStyle(.blue)
                                    .fixedSize(horizontal: true, vertical: false)
                            } else {
                                Button(NSLocalizedString("settings.use", comment: "Use")) {
                                    draftSelectedProviderId = config.id
                                    hasChanges = true
                                }
                                .buttonStyle(.bordered)
                                .fixedSize()
                            }

                            Button(NSLocalizedString("settings.disconnect", comment: "Disconnect")) {
                                settingsViewModel.disconnectProvider(id: config.id)
                            }
                            .buttonStyle(.bordered)
                            .fixedSize()
                        }

                        Button(action: {
                            settingsViewModel.removeProvider(id: config.id)
                            draftConfigs.removeAll { $0.id == config.id }
                            if draftSelectedProviderId == config.id {
                                draftSelectedProviderId = draftConfigs.first?.id
                            }
                            hasChanges = true
                        }) {
                            Image(systemName: "trash")
                                .foregroundStyle(.red.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "globe")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(NSLocalizedString("settings.no_providers", comment: ""))
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(NSLocalizedString("settings.add_provider_hint", comment: ""))
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Auth In Progress

    private var authInProgressView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)

            if let code = settingsViewModel.authUserCode {
                Text(NSLocalizedString("settings.device_code_title", comment: ""))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(code)
                    .font(.system(.title, design: .monospaced))
                    .fontWeight(.bold)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))

                Text(NSLocalizedString("settings.waiting_auth", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text(NSLocalizedString("settings.connecting", comment: ""))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button(NSLocalizedString("action.cancel", comment: "")) {
                settingsViewModel.cancelAuth()
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.blue.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Add Provider Sheet

    private var addProviderSheet: some View {
        VStack(spacing: 20) {
            Text(NSLocalizedString("settings.choose_provider", comment: "Choose Provider"))
                .font(.title3)
                .fontWeight(.semibold)

            VStack(spacing: 12) {
                ForEach(ProviderType.allCases) { type in
                    Button(action: {
                        // Persist immediately so OAuth/API key flows can find this provider
                        settingsViewModel.addProvider(type: type)
                        // Sync drafts from the updated viewmodel state
                        draftConfigs = settingsViewModel.providerConfigs
                        draftSelectedProviderId = settingsViewModel.selectedProviderId
                        hasChanges = false
                        showAddProvider = false
                    }) {
                        HStack(spacing: 16) {
                            Image(systemName: type.iconSystemName)
                                .font(.title2)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(type.displayName)
                                    .fontWeight(.medium)
                                Text(type.defaultModel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .padding(16)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.1), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            Button(NSLocalizedString("action.cancel", comment: "Cancel")) {
                showAddProvider = false
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(32)
        .frame(width: 450)
    }

    // MARK: - API Key Input Sheet

    private var apiKeyInputSheet: some View {
        VStack(spacing: 16) {
            Text(NSLocalizedString("settings.enter_api_key", comment: "Enter API Key"))
                .font(.title3)
                .fontWeight(.semibold)

            if let targetId = apiKeyTargetId,
               let config = draftConfigs.first(where: { $0.id == targetId }) {
                Text(apiKeyHint(for: config.type))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            SecureField("sk-...", text: $apiKeyInput)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 12) {
                Button(NSLocalizedString("action.cancel", comment: "Cancel")) {
                    showAPIKeyInput = false
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button(NSLocalizedString("action.save", comment: "Save")) {
                    if let id = apiKeyTargetId, !apiKeyInput.isEmpty {
                        settingsViewModel.saveAPIKey(apiKeyInput, forProvider: id)
                        if let idx = draftConfigs.firstIndex(where: { $0.id == id }) {
                            draftConfigs[idx].isAuthenticated = true
                            hasChanges = true
                        }
                        showAPIKeyInput = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKeyInput.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(32)
        .frame(width: 400)
    }

    private func apiKeyHint(for type: ProviderType) -> String {
        switch type {
        case .qwen: return NSLocalizedString("settings.qwen_api_key_hint", comment: "")
        case .anthropic: return NSLocalizedString("settings.anthropic_api_key_hint", comment: "")
        case .openai: return NSLocalizedString("settings.openai_api_key_hint", comment: "")
        case .gemini: return NSLocalizedString("settings.gemini_api_key_hint", comment: "")
        }
    }
}
