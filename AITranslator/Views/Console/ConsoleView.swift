import SwiftUI

/// Debug console view showing all app logs with filtering and copy support
struct ConsoleView: View {
    @ObservedObject private var logger = AppLogger.shared
    @State private var searchText = ""
    @State private var selectedLevel: LogLevel? = nil
    @State private var autoScroll = true

    private var filteredEntries: [LogEntry] {
        logger.entries.filter { entry in
            // Level filter
            if let level = selectedLevel, entry.level != level {
                return false
            }
            // Search filter
            if !searchText.isEmpty {
                let query = searchText.lowercased()
                return entry.message.lowercased().contains(query) ||
                       entry.category.lowercased().contains(query) ||
                       (entry.details?.lowercased().contains(query) ?? false)
            }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                // Search
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))

                // Level filter pills
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Button(action: {
                        selectedLevel = selectedLevel == level ? nil : level
                    }) {
                        Text(level.rawValue)
                            .font(.body)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(selectedLevel == level ? Color.accentColor.opacity(0.2) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Actions
                Button(action: copyAll) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy all logs")

                Button(action: { autoScroll.toggle() }) {
                    Image(systemName: autoScroll ? "arrow.down.to.line.compact" : "arrow.down.to.line")
                        .foregroundStyle(autoScroll ? .blue : .secondary)
                }
                .buttonStyle(.plain)
                .help("Auto-scroll")

                Button(action: { logger.clear() }) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Clear console")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // Log entries
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filteredEntries) { entry in
                            LogEntryRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: logger.entries.count) { _ in
                    if autoScroll, let last = filteredEntries.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Status bar
            Divider()
            HStack {
                Text("\(filteredEntries.count) / \(logger.entries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let last = logger.entries.last {
                    Text("Last: \(last.formattedTimestamp)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.bar)
        }
        .frame(minWidth: 600, minHeight: 300)
    }

    private func copyAll() {
        let text = filteredEntries.map { $0.fullText }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Log Entry Row

private struct LogEntryRow: View {
    let entry: LogEntry
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                Text(entry.formattedTimestamp)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)

                Text(entry.level.rawValue)
                    .font(.caption)

                Text("[\(entry.category)]")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(categoryColor)
                    .fontWeight(.semibold)

                Text(entry.message)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(messageColor)
                    .lineLimit(isExpanded ? nil : 2)
                    .textSelection(.enabled)

                Spacer()

                if entry.details != nil {
                    Button(action: { isExpanded.toggle() }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if isExpanded, let details = entry.details {
                Text(details)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 86)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(backgroundColor)
        .contentShape(Rectangle())
        .onTapGesture {
            if entry.details != nil {
                isExpanded.toggle()
            }
        }
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.fullText, forType: .string)
            }
            if entry.details != nil {
                Button("Copy Details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.details ?? "", forType: .string)
                }
            }
        }
    }

    private var categoryColor: Color {
        switch entry.category {
        case "Qwen": return .orange
        case "Claude": return .purple
        case "OAuth": return .blue
        case "Hotkey": return .green
        case "Translation": return .cyan
        default: return .secondary
        }
    }

    private var messageColor: Color {
        switch entry.level {
        case .error: return .red
        case .warning: return .orange
        case .success: return .green
        default: return .primary
        }
    }

    private var backgroundColor: Color {
        switch entry.level {
        case .error: return .red.opacity(0.05)
        case .warning: return .orange.opacity(0.05)
        default: return .clear
        }
    }
}
