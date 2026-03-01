import SwiftUI

/// Settings view for managing AI providers
struct SettingsView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @State private var showAddProvider = false
    @State private var editingProvider: ProviderConfig?
    @State private var apiKeyInput = ""
    @State private var showAPIKeyInput = false
    @State private var apiKeyTargetId: String?

    var body: some View {
        VStack(spacing: 0) {
            // Provider list
            ScrollView {
                VStack(spacing: 12) {
                    // Providers section
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(NSLocalizedString("settings.providers", comment: "AI Providers"))
                                .font(.headline)
                            Spacer()
                            Button(action: { showAddProvider = true }) {
                                Label(
                                    NSLocalizedString("settings.add_provider", comment: "Add Provider"),
                                    systemImage: "plus.circle"
                                )
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }

                        if settingsViewModel.providerConfigs.isEmpty {
                            emptyStateView
                        } else {
                            ForEach(settingsViewModel.providerConfigs) { config in
                                providerRow(config)
                            }
                        }

                        // Global auth error display
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
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.red.opacity(0.1))
                            )
                        }

                        // Device code auth in progress
                        if settingsViewModel.isAuthenticating {
                            authInProgressView
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .sheet(isPresented: $showAddProvider) {
            addProviderSheet
        }
        .sheet(isPresented: $showAPIKeyInput) {
            apiKeyInputSheet
        }
    }

    // MARK: - Auth In Progress

    private var authInProgressView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)

            if let code = settingsViewModel.authUserCode {
                Text(NSLocalizedString("settings.device_code_title", comment: "Enter this code in your browser:"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(code)
                    .font(.system(.title, design: .monospaced))
                    .fontWeight(.bold)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                    )

                Text(NSLocalizedString("settings.waiting_auth", comment: "Waiting for authentication..."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text(NSLocalizedString("settings.connecting", comment: "Connecting..."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button(NSLocalizedString("action.cancel", comment: "Cancel")) {
                settingsViewModel.cancelAuth()
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.background)
                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.blue.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Provider Row

    private func providerRow(_ config: ProviderConfig) -> some View {
        HStack(spacing: 12) {
            // Provider icon
            Image(systemName: config.type.iconSystemName)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                )

            // Provider info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(config.name)
                        .fontWeight(.medium)

                    if settingsViewModel.selectedProviderId == config.id {
                        Text(NSLocalizedString("settings.active", comment: "Active"))
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(.green.opacity(0.2))
                            )
                            .foregroundStyle(.green)
                    }
                }

                HStack(spacing: 4) {
                    Circle()
                        .fill(config.isAuthenticated ? .green : .orange)
                        .frame(width: 6, height: 6)
                    Text(config.isAuthenticated
                         ? NSLocalizedString("settings.connected", comment: "Connected")
                         : NSLocalizedString("settings.not_connected", comment: "Not connected"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("•")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(config.model)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Actions
            HStack(spacing: 8) {
                if !config.isAuthenticated {
                    Button(NSLocalizedString("settings.connect", comment: "Connect")) {
                        settingsViewModel.startOAuth(forProvider: config.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(settingsViewModel.isAuthenticating)

                    Button(NSLocalizedString("settings.api_key", comment: "API Key")) {
                        apiKeyTargetId = config.id
                        apiKeyInput = ""
                        showAPIKeyInput = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    if settingsViewModel.selectedProviderId != config.id {
                        Button(NSLocalizedString("settings.use", comment: "Use")) {
                            settingsViewModel.selectProvider(id: config.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button(NSLocalizedString("settings.disconnect", comment: "Disconnect")) {
                        settingsViewModel.disconnectProvider(id: config.id)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .controlSize(.small)
                }

                // Delete
                Button(action: {
                    settingsViewModel.removeProvider(id: config.id)
                }) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.background)
                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(NSLocalizedString("settings.no_providers", comment: "No providers configured"))
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(NSLocalizedString("settings.add_provider_hint", comment: "Add an AI provider to start translating"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }

    // MARK: - Add Provider Sheet

    private var addProviderSheet: some View {
        VStack(spacing: 20) {
            Text(NSLocalizedString("settings.choose_provider", comment: "Choose Provider"))
                .font(.title3)
                .fontWeight(.semibold)

            VStack(spacing: 10) {
                ForEach(ProviderType.allCases) { type in
                    Button(action: {
                        settingsViewModel.addProvider(type: type)
                        showAddProvider = false
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: type.iconSystemName)
                                .font(.title2)
                                .frame(width: 32)
                            VStack(alignment: .leading) {
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
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.background)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(.quaternary, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Button(NSLocalizedString("action.cancel", comment: "Cancel")) {
                showAddProvider = false
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(24)
        .frame(width: 380)
    }

    // MARK: - API Key Input Sheet

    private var apiKeyInputSheet: some View {
        VStack(spacing: 16) {
            Text(NSLocalizedString("settings.enter_api_key", comment: "Enter API Key"))
                .font(.title3)
                .fontWeight(.semibold)

            if let targetId = apiKeyTargetId,
               let config = settingsViewModel.providerConfigs.first(where: { $0.id == targetId }) {
                Text(apiKeyHint(for: config.type))
                    .font(.caption)
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
                        showAPIKeyInput = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKeyInput.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    /// Provider-specific API key hint
    private func apiKeyHint(for type: ProviderType) -> String {
        switch type {
        case .qwen:
            return NSLocalizedString("settings.qwen_api_key_hint",
                comment: "Get your API key at dashscope.console.aliyun.com")
        case .anthropic:
            return NSLocalizedString("settings.anthropic_api_key_hint",
                comment: "Get your API key at console.anthropic.com")
        }
    }
}
