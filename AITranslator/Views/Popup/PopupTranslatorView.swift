import SwiftUI

/// Compact popup translator that appears on global hotkey
struct PopupTranslatorView: View {
    @EnvironmentObject var viewModel: TranslatorViewModel
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header with language selectors
            HStack(spacing: 8) {
                LanguageSelectorView(
                    selectedLanguage: $viewModel.sourceLanguage,
                    showAutoDetect: true
                )

                Button(action: { viewModel.swapLanguages() }) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.sourceLanguage.code == "auto")

                LanguageSelectorView(
                    selectedLanguage: $viewModel.targetLanguage,
                    showAutoDetect: false
                )

                Spacer()

                // Close button
                Button(action: {
                    NSApp.keyWindow?.close()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(12)

            Divider()

            // Source text (read-only in popup)
            ScrollView {
                Text(viewModel.sourceText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxHeight: 120)
            .background(Color.primary.opacity(0.03))

            Divider()

            // Translation result
            ZStack {
                if viewModel.isTranslating {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(NSLocalizedString("translator.translating", comment: "Translating..."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !viewModel.translatedText.isEmpty {
                    ScrollView {
                        Text(viewModel.translatedText)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                } else if let error = viewModel.error {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    Text(NSLocalizedString("translator.translation", comment: "Translation"))
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)

            Divider()

            // Bottom bar with copy action
            HStack {
                if let provider = settingsViewModel.activeProvider {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(provider.isAuthenticated ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(provider.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button(action: { viewModel.copyTranslation() }) {
                    Label(
                        NSLocalizedString("action.copy", comment: "Copy"),
                        systemImage: "doc.on.doc"
                    )
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.translatedText.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 550, height: 380)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
