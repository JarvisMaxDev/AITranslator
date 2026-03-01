import SwiftUI

/// Reusable translation text panel (source or target)
struct TranslationPanel: View {
    @Binding var text: String
    @Binding var language: Language
    let placeholder: String
    let isSource: Bool
    let isLoading: Bool
    var detectedLanguage: String? = nil

    @State private var isHovering = false
    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Panel header
            HStack(spacing: 8) {
                Image(systemName: isSource ? "text.cursor" : "text.justify.left")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                let titleBase = isSource
                    ? NSLocalizedString("panel.source", comment: "Source")
                    : NSLocalizedString("panel.translation", comment: "Translation")
                let titleText = (isSource && detectedLanguage != nil) 
                    ? "\(titleBase) (\(detectedLanguage!))" 
                    : titleBase

                Text(titleText)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer()

                // Character count for source
                if isSource && !text.isEmpty {
                    Text("\(text.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Text editor area
            ZStack(alignment: .topLeading) {
                if text.isEmpty && !isLoading {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.quaternary)
                        .padding(.leading, 13)
                        .padding(.top, 4)
                }

                if isSource {
                    TextEditor(text: $text)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 4)
                        .padding(.top, 0)
                } else {
                    if isLoading {
                        translatingIndicator
                    } else {
                        ScrollView {
                            Text(text)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.top, 4)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom action bar
            HStack(spacing: 8) {
                if isSource {
                    // Clear button
                    Button(action: {
                        withAnimation(.easeOut(duration: 0.2)) {
                            text = ""
                        }
                    }) {
                        Label(NSLocalizedString("action.clear", comment: "Clear"),
                              systemImage: "xmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(text.isEmpty)
                    .opacity(text.isEmpty ? 0.3 : 1)

                    // Paste button
                    Button(action: {
                        if let clipboard = NSPasteboard.general.string(forType: .string) {
                            text = clipboard
                        }
                    }) {
                        Label(NSLocalizedString("action.paste", comment: "Paste"),
                              systemImage: "doc.on.clipboard")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
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
                        Label(
                            isCopied
                                ? NSLocalizedString("action.copied", comment: "Copied!")
                                : NSLocalizedString("action.copy", comment: "Copy"),
                            systemImage: isCopied ? "checkmark.circle.fill" : "doc.on.doc"
                        )
                        .font(.caption)
                        .foregroundStyle(isCopied ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(text.isEmpty)
                    .opacity(text.isEmpty ? 0.3 : 1)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.background)
                .shadow(color: .black.opacity(isHovering ? 0.15 : 0.08), radius: isHovering ? 8 : 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
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
