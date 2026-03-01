import SwiftUI

/// Reusable translation text panel (source or target)
struct TranslationPanel: View {
    @Binding var text: String
    @Binding var language: Language
    let placeholder: String
    let isSource: Bool
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Text editor area
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 9)
                        .padding(.top, 12)
                }

                if isSource {
                    TextEditor(text: $text)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                } else {
                    if isLoading {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                VStack(spacing: 12) {
                                    ProgressView()
                                        .controlSize(.regular)
                                    Text(NSLocalizedString("translator.translating", comment: "Translating..."))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            Spacer()
                        }
                    } else {
                        ScrollView {
                            Text(text)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Bottom action bar
            HStack(spacing: 12) {
                if isSource {
                    // Clear button
                    Button(action: {
                        text = ""
                    }) {
                        Image(systemName: "xmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help(NSLocalizedString("action.clear", comment: "Clear"))
                    .disabled(text.isEmpty)
                    .opacity(text.isEmpty ? 0.3 : 1)
                } else {
                    // Copy button
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help(NSLocalizedString("action.copy", comment: "Copy"))
                    .disabled(text.isEmpty)
                    .opacity(text.isEmpty ? 0.3 : 1)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}
