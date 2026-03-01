import SwiftUI

/// Main translator view with two panels side by side
struct TranslatorView: View {
    @EnvironmentObject var viewModel: TranslatorViewModel
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar area
            toolbarArea
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()

            // Translation panels
            HSplitView {
                // Source panel
                TranslationPanel(
                    text: $viewModel.sourceText,
                    language: $viewModel.sourceLanguage,
                    placeholder: NSLocalizedString("translator.enter_text", comment: "Enter text to translate..."),
                    isSource: true,
                    isLoading: false
                )
                .frame(minWidth: 300)

                // Target panel
                TranslationPanel(
                    text: .constant(viewModel.translatedText),
                    language: $viewModel.targetLanguage,
                    placeholder: NSLocalizedString("translator.translation", comment: "Translation"),
                    isSource: false,
                    isLoading: viewModel.isTranslating
                )
                .frame(minWidth: 300)
            }

            Divider()

            // Status bar
            statusBar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .background(.background)
    }

    // MARK: - Toolbar

    private var toolbarArea: some View {
        HStack(spacing: 12) {
            // Source language selector
            LanguageSelectorView(
                selectedLanguage: $viewModel.sourceLanguage,
                showAutoDetect: true,
                detectedLanguage: viewModel.detectedLanguage
            )

            // Swap button
            Button(action: { viewModel.swapLanguages() }) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("translator.swap_languages", comment: "Swap languages"))
            .disabled(viewModel.sourceLanguage.code == "auto" && viewModel.detectedLanguage == nil)

            // Target language selector
            LanguageSelectorView(
                selectedLanguage: $viewModel.targetLanguage,
                showAutoDetect: false
            )

            Spacer()

            // Translate button
            Button(action: {
                Task { await viewModel.translate() }
            }) {
                HStack(spacing: 6) {
                    if viewModel.isTranslating {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.8)
                    }
                    Text(NSLocalizedString("translator.translate", comment: "Translate"))
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(viewModel.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isTranslating)

            // Settings button
            Button(action: {
                openWindow(id: "settings")
            }) {
                Image(systemName: "gearshape")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .help(NSLocalizedString("translator.settings", comment: "Settings"))
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            // Provider indicator
            if let provider = settingsViewModel.activeProvider {
                HStack(spacing: 4) {
                    Circle()
                        .fill(provider.isAuthenticated ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(provider.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let models = settingsViewModel.modelsForProvider(provider.id)
                    if let modelName = models.first(where: { $0.id == provider.model })?.name {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(modelName)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text(NSLocalizedString("status.no_provider", comment: "No provider configured"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Character count
            Text("\(viewModel.characterCount) / \(Constants.maxTextLength)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            // Error indicator
            if let error = viewModel.error {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
        }
    }
}
