import Foundation
import Combine

// MARK: - LocalModel

/// Represents a single GGUF model entry in the catalog.
///
/// Built-in models are shipped with the app catalog; custom models are added
/// by the user via a HuggingFace repository URL.
struct LocalModel: Identifiable, Codable, Equatable {
    /// Unique slug identifier, e.g. `"gemma-3-1b"`.
    let id: String
    /// Human-readable display name, e.g. `"Gemma 3 1B"`.
    let name: String
    /// GGUF file name on disk, e.g. `"gemma-3-1b-it-Q4_K_M.gguf"`.
    let fileName: String
    /// Direct download URL (HuggingFace resolve endpoint).
    let downloadURL: String
    /// Approximate file size in bytes.
    let sizeBytes: Int64
    /// Short quality/capability description shown in the UI.
    let description: String
    /// `true` for models shipped in the built-in catalog; `false` for user-added models.
    let isBuiltIn: Bool
}

// MARK: - ModelState

/// Lifecycle state of a catalog model.
enum ModelState: Equatable {
    /// Model file is not present on disk.
    case notDownloaded
    /// Download is in progress. `progress` is in the range `0.0 … 1.0`.
    case downloading(progress: Double)
    /// Model file is present on disk but not currently loaded.
    case downloaded
    /// Model is loaded and actively used for inference.
    case active
}

// MARK: - DownloadDelegate

/// NSObject-based delegate that receives `URLSession` download callbacks and forwards
/// progress/completion events back to `ModelCatalog` on the main actor.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    // MARK: Internal state (protected by lock)

    private let lock = NSLock()
    private var targetModel: LocalModel?
    private var modelsDirectory: URL?
    private var onProgress: (@Sendable (Double) -> Void)?
    private var onCompletion: (@Sendable (Result<URL, Error>) -> Void)?

    // MARK: Configuration

    func configure(
        model: LocalModel,
        directory: URL,
        onProgress: @escaping @Sendable (Double) -> Void,
        onCompletion: @escaping @Sendable (Result<URL, Error>) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.targetModel = model
        self.modelsDirectory = directory
        self.onProgress = onProgress
        self.onCompletion = onCompletion
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        targetModel = nil
        modelsDirectory = nil
        onProgress = nil
        onCompletion = nil
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        lock.lock()
        let callback = onProgress
        lock.unlock()
        callback?(progress)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let model = targetModel
        let directory = modelsDirectory
        let completion = onCompletion
        lock.unlock()

        guard let model, let directory else {
            completion?(.failure(CatalogError.delegateNotConfigured))
            reset()
            return
        }

        let destination = directory.appendingPathComponent(model.fileName)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            completion?(.success(destination))
        } catch {
            completion?(.failure(error))
        }
        reset()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }

        lock.lock()
        let completion = onCompletion
        lock.unlock()

        completion?(.failure(error))
        reset()
    }
}

// MARK: - CatalogError

/// Errors produced by ``ModelCatalog``.
enum CatalogError: LocalizedError {
    case invalidURL(String)
    case huggingFaceAPIFailed(Int)
    case noGGUFFileFound(String)
    case delegateNotConfigured
    case downloadAlreadyInProgress

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .huggingFaceAPIFailed(let status):
            return "HuggingFace API returned HTTP \(status)"
        case .noGGUFFileFound(let repo):
            return "No .gguf file found in repository: \(repo)"
        case .delegateNotConfigured:
            return "Download delegate was not configured before use"
        case .downloadAlreadyInProgress:
            return "A download is already in progress"
        }
    }
}

// MARK: - ModelCatalog

/// Observable catalog of local GGUF models with download management.
///
/// Owns a built-in list of Gemma models and supports user-added custom models
/// sourced from any HuggingFace repository that exposes a `.gguf` file.
///
/// All mutations happen on the main actor; background work (network I/O, file
/// operations) is dispatched via `Task` with structured concurrency.
///
/// Example:
/// ```swift
/// @StateObject private var catalog = ModelCatalog()
///
/// // In a view:
/// catalog.downloadModel(catalog.models[0])
/// ```
@MainActor
final class ModelCatalog: ObservableObject {

    // MARK: Published state

    /// All known models — built-in catalog entries followed by user-added models.
    @Published var models: [LocalModel] = []

    /// Per-model download / availability state keyed by ``LocalModel/id``.
    @Published var modelStates: [String: ModelState] = [:]

    /// ID of the model currently selected for inference.
    @Published var activeModelId: String?

    /// Last download error message, or `nil` if no error has occurred.
    @Published var downloadError: String?

    // MARK: Private state

    private var activeDownloadTask: URLSessionDownloadTask?
    private let delegate = DownloadDelegate()
    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    }()

    // MARK: UserDefaults keys

    private enum DefaultsKey {
        static let activeModelId = "localModelActiveId"
        static let customModels = "localModelCustomModels"
    }

    // MARK: Built-in catalog

    private static let builtInModels: [LocalModel] = [
        LocalModel(
            id: "gemma-3-1b",
            name: "Gemma 3 1B",
            fileName: "gemma-3-1b-it-Q4_K_M.gguf",
            downloadURL: "https://huggingface.co/ggml-org/gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it-Q4_K_M.gguf",
            sizeBytes: 756_000_000,
            description: "Basic quality, fast. Good for simple translations.",
            isBuiltIn: true
        ),
        LocalModel(
            id: "gemma-3-4b",
            name: "Gemma 3 4B",
            fileName: "gemma-3-4b-it-Q4_K_M.gguf",
            downloadURL: "https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf",
            sizeBytes: 2_800_000_000,
            description: "Good quality, balanced speed and accuracy.",
            isBuiltIn: true
        ),
        LocalModel(
            id: "gemma-3-12b",
            name: "Gemma 3 12B",
            fileName: "gemma-3-12b-it-Q4_K_M.gguf",
            downloadURL: "https://huggingface.co/ggml-org/gemma-3-12b-it-GGUF/resolve/main/gemma-3-12b-it-Q4_K_M.gguf",
            sizeBytes: 7_300_000_000,
            description: "Excellent quality, requires 8+ GB RAM.",
            isBuiltIn: true
        )
    ]

    // MARK: Initialisation

    /// Creates the catalog, loads persisted custom models, and scans disk for
    /// already-downloaded files.
    init() {
        models = Self.builtInModels + loadCustomModels()
        activeModelId = UserDefaults.standard.string(forKey: DefaultsKey.activeModelId)
        refreshStates()
    }

    // MARK: - Computed properties

    /// Absolute path to the directory where GGUF model files are stored.
    ///
    /// Created on first access if it does not already exist.
    var modelsDirectory: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport
            .appendingPathComponent("AITranslator", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
        }
        return dir
    }

    /// Full file-system path to the GGUF file for the given model.
    ///
    /// - Parameter model: The model whose path is requested.
    /// - Returns: Absolute path string (file may or may not exist on disk).
    func modelPath(for model: LocalModel) -> String {
        modelsDirectory.appendingPathComponent(model.fileName).path
    }

    // MARK: - Download

    /// Begin downloading `model` from its ``LocalModel/downloadURL``.
    ///
    /// Progress is reflected in ``modelStates`` as `.downloading(progress:)`.
    /// Completes with `.downloaded` or resets to `.notDownloaded` on failure.
    ///
    /// - Parameter model: The model to download. Silently ignored if the model
    ///   is already downloaded/active or a download is already in progress.
    func downloadModel(_ model: LocalModel) {
        guard
            modelStates[model.id] == .notDownloaded ||
            modelStates[model.id] == nil
        else { return }

        guard activeDownloadTask == nil else {
            downloadError = CatalogError.downloadAlreadyInProgress.localizedDescription
            return
        }

        guard let url = URL(string: model.downloadURL) else {
            downloadError = CatalogError.invalidURL(model.downloadURL).localizedDescription
            return
        }

        downloadError = nil
        modelStates[model.id] = .downloading(progress: 0)

        let directory = modelsDirectory

        delegate.configure(
            model: model,
            directory: directory,
            onProgress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.modelStates[model.id] = .downloading(progress: progress)
                }
            },
            onCompletion: { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.handleDownloadCompletion(model: model, result: result)
                }
            }
        )

        let task = session.downloadTask(with: url)
        activeDownloadTask = task
        task.resume()

        AppLogger.info("ModelCatalog", "Download started", details: "\(model.name) — \(model.fileName)")
    }

    /// Cancel an in-progress download.
    ///
    /// The model state is reset to `.notDownloaded`.
    func cancelDownload() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil

        // Reset any model that is currently in a downloading state.
        for (id, state) in modelStates {
            if case .downloading = state {
                modelStates[id] = .notDownloaded
            }
        }

        delegate.reset()
        AppLogger.info("ModelCatalog", "Download cancelled")
    }

    // MARK: - File management

    /// Delete the GGUF file for `model` from disk and update its state.
    ///
    /// - Parameter model: The model whose file should be removed.
    func deleteModel(_ model: LocalModel) {
        let path = modelPath(for: model)
        do {
            try FileManager.default.removeItem(atPath: path)
            modelStates[model.id] = .notDownloaded
            // Deselect if this was the active model.
            if activeModelId == model.id {
                activeModelId = nil
                UserDefaults.standard.removeObject(forKey: DefaultsKey.activeModelId)
            }
            AppLogger.info("ModelCatalog", "Model deleted", details: model.fileName)
        } catch {
            AppLogger.error("ModelCatalog", "Failed to delete model", details: error.localizedDescription)
        }
    }

    // MARK: - Selection

    /// Mark `model` as the active model for inference and persist the choice.
    ///
    /// - Parameter model: The model to activate. Must already be downloaded.
    func selectModel(_ model: LocalModel) {
        guard
            modelStates[model.id] == .downloaded ||
            modelStates[model.id] == .active
        else { return }

        // Demote the previously active model back to downloaded.
        if let previousId = activeModelId, previousId != model.id {
            modelStates[previousId] = .downloaded
        }

        activeModelId = model.id
        modelStates[model.id] = .active
        UserDefaults.standard.set(model.id, forKey: DefaultsKey.activeModelId)
        AppLogger.info("ModelCatalog", "Model selected", details: model.name)
    }

    // MARK: - Custom model addition

    /// Resolve a HuggingFace repository, locate the first `.gguf` file, add it
    /// to the model list, and begin downloading it.
    ///
    /// - Parameter huggingFaceRepo: Repo identifier in `"owner/repo"` format,
    ///   e.g. `"ggml-org/gemma-3-1b-it-GGUF"`.
    func addCustomModel(huggingFaceRepo: String) {
        Task {
            do {
                let model = try await resolveCustomModel(repo: huggingFaceRepo)
                if !models.contains(where: { $0.id == model.id }) {
                    models.append(model)
                    persistCustomModels()
                }
                downloadModel(model)
            } catch {
                downloadError = error.localizedDescription
                AppLogger.error("ModelCatalog", "Failed to add custom model", details: error.localizedDescription)
            }
        }
    }

    // MARK: - State refresh

    /// Scan the models directory on disk and synchronise ``modelStates``.
    ///
    /// Call this after app launch or when returning from background to catch
    /// files that were added or removed outside the app.
    func refreshStates() {
        for model in models {
            let path = modelPath(for: model)
            let exists = FileManager.default.fileExists(atPath: path)
            let currentState = modelStates[model.id]

            // Do not overwrite in-progress downloads.
            if case .downloading = currentState { continue }

            if model.id == activeModelId && exists {
                modelStates[model.id] = .active
            } else if exists {
                modelStates[model.id] = .downloaded
            } else {
                modelStates[model.id] = .notDownloaded
            }
        }
    }

    // MARK: - Display helpers

    /// Format a byte count into a human-readable string (KB / MB / GB).
    ///
    /// - Parameter bytes: Number of bytes to format.
    /// - Returns: Locale-formatted string with appropriate unit, e.g. `"2.8 GB"`.
    static func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Private helpers

    private func handleDownloadCompletion(model: LocalModel, result: Result<URL, Error>) {
        activeDownloadTask = nil
        switch result {
        case .success:
            modelStates[model.id] = model.id == activeModelId ? .active : .downloaded
            AppLogger.success("ModelCatalog", "Download finished", details: model.fileName)
        case .failure(let error):
            modelStates[model.id] = .notDownloaded
            downloadError = error.localizedDescription
            AppLogger.error("ModelCatalog", "Download failed", details: error.localizedDescription)
        }
    }

    /// Fetch HuggingFace model metadata and construct a `LocalModel` for the
    /// first `.gguf` sibling found.
    private func resolveCustomModel(repo: String) async throws -> LocalModel {
        let apiURLString = "https://huggingface.co/api/models/\(repo)"
        guard let apiURL = URL(string: apiURLString) else {
            throw CatalogError.invalidURL(apiURLString)
        }

        let (data, response) = try await URLSession.shared.data(from: apiURL)

        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode != 200 {
            throw CatalogError.huggingFaceAPIFailed(httpResponse.statusCode)
        }

        // HF API response shape: { "siblings": [{ "rfilename": "model.gguf" }] }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let siblings = json["siblings"] as? [[String: Any]]
        else {
            throw CatalogError.noGGUFFileFound(repo)
        }

        guard let sibling = siblings.first(where: {
            ($0["rfilename"] as? String)?.hasSuffix(".gguf") == true
        }),
              let fileName = sibling["rfilename"] as? String
        else {
            throw CatalogError.noGGUFFileFound(repo)
        }

        // Derive a stable id from the full repo path to avoid collisions
        let repoName = repo.split(separator: "/").last.map(String.init) ?? repo
        let sanitized = repo.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        guard !sanitized.isEmpty else {
            throw CatalogError.invalidURL(repo)
        }
        let modelId = "custom-\(sanitized)"
        // Prefix fileName with sanitized repo to avoid on-disk collisions
        let uniqueFileName = "\(sanitized)--\(fileName)"
        let downloadURL = "https://huggingface.co/\(repo)/resolve/main/\(fileName)"

        return LocalModel(
            id: modelId,
            name: repoName,
            fileName: uniqueFileName,
            downloadURL: downloadURL,
            sizeBytes: 0,           // size unknown until download completes
            description: "Custom model from \(repo)",
            isBuiltIn: false
        )
    }

    // MARK: - Custom model persistence

    private func loadCustomModels() -> [LocalModel] {
        guard
            let data = UserDefaults.standard.data(forKey: DefaultsKey.customModels),
            let decoded = try? JSONDecoder().decode([LocalModel].self, from: data)
        else { return [] }
        return decoded
    }

    private func persistCustomModels() {
        let custom = models.filter { !$0.isBuiltIn }
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.customModels)
        }
    }
}
