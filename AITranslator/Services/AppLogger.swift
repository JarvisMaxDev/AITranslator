import Foundation
import Combine

/// Log entry severity level
enum LogLevel: String, CaseIterable {
    case info = "ℹ️"
    case request = "➡️"
    case response = "⬅️"
    case success = "✅"
    case warning = "⚠️"
    case error = "❌"
}

/// A single log entry
struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let category: String
    let message: String
    let details: String?

    var formattedTimestamp: String {
        Self.formatter.string(from: timestamp)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Full text representation for copying
    var fullText: String {
        var text = "[\(formattedTimestamp)] \(level.rawValue) [\(category)] \(message)"
        if let details = details, !details.isEmpty {
            text += "\n\(details)"
        }
        return text
    }
}

/// Centralized logger that captures app events for the debug console
@MainActor
final class AppLogger: ObservableObject {
    static let shared = AppLogger()

    @Published private(set) var entries: [LogEntry] = []

    /// Maximum number of entries to keep
    private let maxEntries = 500

    private init() {}

    /// Log a message
    func log(_ level: LogLevel, category: String, message: String, details: String? = nil) {
        let entry = LogEntry(
            timestamp: Date(),
            level: level,
            category: category,
            message: message,
            details: details
        )
        entries.append(entry)

        // Trim old entries
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        // Also print to Xcode console
        print("[\(entry.formattedTimestamp)] \(level.rawValue) [\(category)] \(message)")
        if let details = details {
            print("  → \(details.prefix(200))")
        }
    }

    /// Clear all entries
    func clear() {
        entries.removeAll()
    }

    /// Export all entries as text
    func exportAsText() -> String {
        entries.map { $0.fullText }.joined(separator: "\n\n")
    }

    // MARK: - Convenience methods

    func info(_ category: String, _ message: String, details: String? = nil) {
        log(.info, category: category, message: message, details: details)
    }

    func request(_ category: String, _ message: String, details: String? = nil) {
        log(.request, category: category, message: message, details: details)
    }

    func response(_ category: String, _ message: String, details: String? = nil) {
        log(.response, category: category, message: message, details: details)
    }

    func success(_ category: String, _ message: String, details: String? = nil) {
        log(.success, category: category, message: message, details: details)
    }

    func warning(_ category: String, _ message: String, details: String? = nil) {
        log(.warning, category: category, message: message, details: details)
    }

    func error(_ category: String, _ message: String, details: String? = nil) {
        log(.error, category: category, message: message, details: details)
    }

    // MARK: - Non-isolated access (safe from any context)

    nonisolated static func info(_ category: String, _ message: String, details: String? = nil) {
        Task { @MainActor in shared.info(category, message, details: details) }
    }
    nonisolated static func request(_ category: String, _ message: String, details: String? = nil) {
        Task { @MainActor in shared.request(category, message, details: details) }
    }
    nonisolated static func response(_ category: String, _ message: String, details: String? = nil) {
        Task { @MainActor in shared.response(category, message, details: details) }
    }
    nonisolated static func success(_ category: String, _ message: String, details: String? = nil) {
        Task { @MainActor in shared.success(category, message, details: details) }
    }
    nonisolated static func warning(_ category: String, _ message: String, details: String? = nil) {
        Task { @MainActor in shared.warning(category, message, details: details) }
    }
    nonisolated static func error(_ category: String, _ message: String, details: String? = nil) {
        Task { @MainActor in shared.error(category, message, details: details) }
    }
}
