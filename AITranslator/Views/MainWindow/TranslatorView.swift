import SwiftUI

/// Main translator view with two panels side by side
struct TranslatorView: View {
    @EnvironmentObject var viewModel: TranslatorViewModel
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.openWindow) private var openWindow

    @State private var swapRotation: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            // Top control bar
            ZStack {
                HStack(spacing: 8) {
                    LanguageSelectorView(
                        selectedLanguage: $viewModel.sourceLanguage,
                        showAutoDetect: true,
                        detectedLanguage: viewModel.detectedLanguage
                    )

                    Button(action: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                            swapRotation += 180
                            viewModel.swapLanguages()
                        }
                    }) {
                        Image(systemName: "arrow.left.arrow.right")
                            .rotationEffect(.degrees(swapRotation))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .help(NSLocalizedString("translator.swap_languages", comment: "Swap languages"))
                    .disabled(viewModel.sourceLanguage.code == "auto" && viewModel.detectedLanguage == nil)

                    LanguageSelectorView(
                        selectedLanguage: $viewModel.targetLanguage,
                        showAutoDetect: false
                    )
                }

                HStack(spacing: 12) {
                    Spacer()
                    Button(action: {
                        Task { await viewModel.translate() }
                    }) {
                        Text(NSLocalizedString("translator.translate", comment: "Translate"))
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(viewModel.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isTranslating)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Translation panels
            HSplitView {
                // Source panel
                TranslationPanel(
                    text: $viewModel.sourceText,
                    language: $viewModel.sourceLanguage,
                    placeholder: "",
                    isSource: true,
                    isLoading: false,
                    detectedLanguage: viewModel.detectedLanguage?.name,
                    onBeforeTextChange: { viewModel.saveState() }
                )
                .frame(minWidth: 250, maxWidth: .infinity, maxHeight: .infinity)

                // Target panel
                TranslationPanel(
                    text: .constant(viewModel.translatedText),
                    language: $viewModel.targetLanguage,
                    placeholder: "",
                    isSource: false,
                    isLoading: viewModel.isTranslating
                )
                .frame(minWidth: 250, maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            // Status bar
            statusBar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(height: 38)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("macOS Translator")
        // Minimal native toolbar for the settings gear, keeping it out of the main layout, similar to standard apps
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }) {
                    Image(systemName: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            // Error indicator or Provider badge
            if let error = viewModel.error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if let provider = settingsViewModel.activeProvider {
                HStack(spacing: 6) {
                    Image(systemName: provider.type.iconSystemName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text(provider.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    let models = settingsViewModel.modelsForProvider(provider.id)
                    let displayModel = models.first(where: { $0.id == provider.model })?.name ?? provider.model

                    if !displayModel.isEmpty {
                        Text(displayModel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
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
                Text("\(viewModel.characterCount) / \(Constants.maxTextLength)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .animation(.easeInOut, value: viewModel.error)
    }
}
