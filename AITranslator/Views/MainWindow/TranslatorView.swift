import SwiftUI
import UniformTypeIdentifiers

/// Main translator view with two panels side by side
struct TranslatorView: View {
    @EnvironmentObject var viewModel: TranslatorViewModel
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.openWindow) private var openWindow

    @AppStorage(Constants.UserDefaultsKeys.fontSize) private var fontSize: Double = 14
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

                    // Load document button
                    Button(action: {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.plainText, .pdf]
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        panel.message = NSLocalizedString("document.load", comment: "Select a document to translate")
                        if panel.runModal() == .OK, let url = panel.url {
                            viewModel.processDocument(url: url)
                        }
                    }) {
                        Image(systemName: "doc.text")
                    }
                    .buttonStyle(.bordered)
                    .help(NSLocalizedString("document.load", comment: "Load document"))
                    .disabled(viewModel.isTranslating)

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
                    isLoading: viewModel.isProcessingOCR,
                    fontSize: CGFloat(fontSize),
                    detectedLanguage: viewModel.detectedLanguage?.name,
                    onBeforeTextChange: { viewModel.saveState() },
                    onImagePasted: { image in
                        Task { await viewModel.processImage(image) }
                    }
                )
                .frame(minWidth: 250, maxWidth: .infinity, maxHeight: .infinity)

                // Target panel
                TranslationPanel(
                    text: .constant(viewModel.translatedText),
                    language: $viewModel.targetLanguage,
                    placeholder: "",
                    isSource: false,
                    isLoading: viewModel.isTranslating,
                    fontSize: CGFloat(fontSize)
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

            // Document progress bar
            if viewModel.isDocumentMode {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let name = viewModel.documentFileName {
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if viewModel.isTranslating {
                        ProgressView(value: viewModel.documentProgress)
                            .frame(maxWidth: 200)

                        Text("\(Int(viewModel.documentProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)

                        Button(action: { viewModel.cancelDocument() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(NSLocalizedString("document.cancel", comment: "Cancel"))
                    } else if !viewModel.translatedText.isEmpty {
                        Spacer()

                        Button(action: { viewModel.exportDocument() }) {
                            Label(NSLocalizedString("document.export", comment: "Export"),
                                  systemImage: "square.and.arrow.up")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button(action: { viewModel.exitDocumentMode() }) {
                            Image(systemName: "xmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(NSLocalizedString("document.close", comment: "Close document mode"))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

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
        // Font size keyboard shortcuts
        .background(
            Group {
                Button("") { fontSize = min(fontSize + 1, 24) }
                    .keyboardShortcut("+", modifiers: .command)
                    .hidden()
                Button("") { fontSize = max(fontSize - 1, 10) }
                    .keyboardShortcut("-", modifiers: .command)
                    .hidden()
            }
        )
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

            // Font size controls
            HStack(spacing: 4) {
                Button(action: { fontSize = max(fontSize - 1, 10) }) {
                    Image(systemName: "textformat.size.smaller")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("action.font_smaller", comment: "Decrease font size"))

                Text("\(Int(fontSize))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .frame(minWidth: 18)

                Button(action: { fontSize = min(fontSize + 1, 24) }) {
                    Image(systemName: "textformat.size.larger")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("action.font_larger", comment: "Increase font size"))
            }

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
