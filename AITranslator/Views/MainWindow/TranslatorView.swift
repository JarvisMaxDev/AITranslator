import SwiftUI

/// Main translator view with two panels side by side
struct TranslatorView: View {
    @EnvironmentObject var viewModel: TranslatorViewModel
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.openWindow) private var openWindow

    @State private var swapRotation: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar area
            toolbarArea
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            // Translation panels
            HStack(spacing: 12) {
                // Source panel
                TranslationPanel(
                    text: $viewModel.sourceText,
                    language: $viewModel.sourceLanguage,
                    placeholder: NSLocalizedString("translator.enter_text", comment: "Enter text to translate..."),
                    isSource: true,
                    isLoading: false,
                    detectedLanguage: viewModel.detectedLanguage?.name
                )

                // Target panel
                TranslationPanel(
                    text: .constant(viewModel.translatedText),
                    language: $viewModel.targetLanguage,
                    placeholder: NSLocalizedString("translator.translation", comment: "Translation"),
                    isSource: false,
                    isLoading: viewModel.isTranslating
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Status bar
            statusBar
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .padding(.top, 4)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

            // Swap button with rotation animation
            Button(action: {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                    swapRotation += 180
                    viewModel.swapLanguages()
                }
            }) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(swapRotation))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.quaternary.opacity(0.5))
                    )
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
                    } else {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 14))
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
                    .font(.system(size: 14))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.quaternary.opacity(0.5))
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .help(NSLocalizedString("translator.settings", comment: "Settings"))
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            // Provider indicator with icon
            if let provider = settingsViewModel.activeProvider {
                HStack(spacing: 6) {
                    Image(systemName: provider.type.iconSystemName)
                        .font(.caption)
                        .foregroundStyle(provider.isAuthenticated ? .green : .orange)

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

                    // Auth method badge
                    if provider.authMethod == .oauth {
                        Text("OAuth")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(.quaternary)
                            )
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(NSLocalizedString("status.no_provider", comment: "No provider configured"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Character count
            HStack(spacing: 4) {
                Image(systemName: "character.cursor.ibeam")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text("\(viewModel.characterCount) / \(Constants.maxTextLength)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            // Error indicator
            if let error = viewModel.error {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
    }
}
