import SwiftUI
import UniformTypeIdentifiers

/// Reusable translation text panel (source or target)
struct TranslationPanel: View {
    @Binding var text: String
    @Binding var language: Language
    let placeholder: String
    let isSource: Bool
    let isLoading: Bool
    var detectedLanguage: String? = nil
    var onBeforeTextChange: (() -> Void)? = nil
    var onImagePasted: ((NSImage) -> Void)? = nil

    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Panel header
            HStack(spacing: 8) {
                let titleText = (isSource && language.code == "auto" && detectedLanguage != nil) 
                    ? "\(language.name) (\(detectedLanguage!))" 
                    : language.name

                Text(titleText)
                    .font(.body)
                    .foregroundStyle(.secondary)

                Spacer()

                // Character count for source
                if isSource && !text.isEmpty {
                    Text("\(text.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 6)

            // Text editor area
            ZStack(alignment: .topLeading) {
                if text.isEmpty && !isLoading {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.quaternary)
                        .padding(.leading, 20)
                        .padding(.top, 8)
                }

                if isSource {
                    TextEditor(text: $text)
                        .font(.body)
                        .lineSpacing(3)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 16)
                        .padding(.top, 0)
                } else {
                    if isLoading && text.isEmpty {
                        // Show spinner only when waiting for first chunk
                        translatingIndicator
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(text)
                                    .font(.body)
                                    .lineSpacing(3)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                // Streaming cursor: animated dots after text
                                if isLoading {
                                    HStack(spacing: 3) {
                                        ForEach(0..<3, id: \.self) { i in
                                            Circle()
                                                .fill(.secondary)
                                                .frame(width: 4, height: 4)
                                                .opacity(0.4)
                                                .animation(
                                                    .easeInOut(duration: 0.5)
                                                    .repeatForever(autoreverses: true)
                                                    .delay(Double(i) * 0.15),
                                                    value: isLoading
                                                )
                                        }
                                    }
                                    .padding(.top, 4)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom action bar
            HStack(spacing: 12) {
                Spacer()
                
                if isSource {
                    // Paste button — detects image in clipboard
                    Button(action: {
                        if OCRService.clipboardContainsImage(), let image = OCRService.imageFromClipboard() {
                            // Image in clipboard — run OCR
                            onImagePasted?(image)
                        } else if let clipboard = NSPasteboard.general.string(forType: .string) {
                            onBeforeTextChange?()
                            text = clipboard
                        }
                    }) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(NSLocalizedString("action.paste", comment: "Paste"))

                    // Load image button — opens file picker
                    Button(action: {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.image, .png, .jpeg, .tiff, .bmp]
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        panel.message = NSLocalizedString("ocr.select_image", comment: "Select an image for text recognition")
                        if panel.runModal() == .OK, let url = panel.url,
                           let image = OCRService.imageFromFile(url) {
                            onImagePasted?(image)
                        }
                    }) {
                        Image(systemName: "photo")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(NSLocalizedString("ocr.load_image", comment: "Load image for OCR"))

                    // Clear button
                    Button(action: {
                        onBeforeTextChange?()
                        withAnimation(.easeOut(duration: 0.2)) {
                            text = ""
                        }
                    }) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(NSLocalizedString("action.clear", comment: "Clear"))
                    .disabled(text.isEmpty)
                    .opacity(text.isEmpty ? 0.3 : 1)
                } else {
                    // Copy button with feedback
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isCopied = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { isCopied = false }
                        }
                    }) {
                        Image(systemName: isCopied ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.system(size: 13))
                            .foregroundStyle(isCopied ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isCopied ? NSLocalizedString("action.copied", comment: "Copied!") : NSLocalizedString("action.copy", comment: "Copy"))
                    .disabled(text.isEmpty)
                    .opacity(text.isEmpty ? 0.3 : 1)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Color.clear)
    }

    // MARK: - Translating Indicator

    private var translatingIndicator: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.regular)

                    Text(NSLocalizedString("translator.translating", comment: "Translating..."))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Animated dots
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(.secondary)
                                .frame(width: 4, height: 4)
                                .opacity(0.4)
                                .animation(
                                    .easeInOut(duration: 0.6)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(i) * 0.2),
                                    value: isLoading
                                )
                        }
                    }
                }
                Spacer()
            }
            Spacer()
        }
    }
}
