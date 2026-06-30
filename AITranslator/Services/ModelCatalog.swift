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

// MARK: - GGUFModelCandidate

enum GGUFSourceKind: String, Sendable {
    case direct
    case sameOwner
    case ggml
    case trusted
    case community
}

/// A concrete downloadable GGUF file resolved from a HuggingFace model page.
struct GGUFModelCandidate: Identifiable, Equatable, Sendable {
    let repo: String
    let remoteFileName: String
    let localFileName: String
    let downloadURL: String
    let modelName: String
    let description: String
    let sourceKind: GGUFSourceKind
    let sortRank: Int
    let fileRank: Int
    let downloadCount: Int

    var id: String { "\(repo)|\(remoteFileName)" }
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

    private func takeCompletionState() -> (
        model: LocalModel?,
        directory: URL?,
        completion: (@Sendable (Result<URL, Error>) -> Void)?
    ) {
        lock.lock()
        defer { lock.unlock() }
        let model = targetModel
        let directory = modelsDirectory
        let completion = onCompletion
        onCompletion = nil
        return (model: model, directory: directory, completion: completion)
    }

    private func takeCompletion() -> (@Sendable (Result<URL, Error>) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        let completion = onCompletion
        onCompletion = nil
        return completion
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
        let (model, directory, completion) = takeCompletionState()
        guard let completion else {
            reset()
            return
        }

        if let httpResponse = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            completion(.failure(CatalogError.huggingFaceAPIFailed(httpResponse.statusCode)))
            reset()
            return
        }

        guard let model, let directory else {
            completion(.failure(CatalogError.delegateNotConfigured))
            reset()
            return
        }

        let destination = directory.appendingPathComponent(model.fileName)
        do {
            let handle = try FileHandle(forReadingFrom: location)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 4) ?? Data()
            guard header == Data("GGUF".utf8) else {
                throw CatalogError.invalidGGUFDownload(model.fileName)
            }

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            completion(.success(destination))
        } catch {
            completion(.failure(error))
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

        guard let completion = takeCompletion() else { return }

        completion(.failure(error))
        reset()
    }
}

// MARK: - CatalogError

/// Errors produced by ``ModelCatalog``.
enum CatalogError: LocalizedError {
    case invalidURL(String)
    case invalidRepositoryInput(String)
    case huggingFaceAPIFailed(Int)
    case noGGUFFileFound(String)
    case noCompatibleGGUFFileFound(String)
    case onlyUnsupportedGGUFFilesFound(String)
    case onlyRuntimeUnsupportedGGUFFilesFound(String)
    case invalidGGUFDownload(String)
    case delegateNotConfigured
    case downloadAlreadyInProgress

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .invalidRepositoryInput(let input):
            return "Enter a HuggingFace model in owner/repo format or paste a huggingface.co model URL: \(input)"
        case .huggingFaceAPIFailed(let status):
            return "HuggingFace API returned HTTP \(status)"
        case .noGGUFFileFound(let repo):
            return "No .gguf file found in repository: \(repo)"
        case .noCompatibleGGUFFileFound(let repo):
            return "No compatible GGUF conversion found for: \(repo)"
        case .onlyUnsupportedGGUFFilesFound(let repo):
            return "Only unsupported GGUF files were found for: \(repo). Split GGUF, mmproj, and MTP files are not supported yet."
        case .onlyRuntimeUnsupportedGGUFFilesFound(let repo):
            return "GGUF files were found for \(repo), but they require a newer local inference runtime than the bundled llama.cpp. Try Gemma 3 or Qwen GGUF for now."
        case .invalidGGUFDownload(let fileName):
            return "Downloaded file is not a valid GGUF model: \(fileName)"
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
    private lazy var cachedModelsDirectory: URL = {
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
    }()
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
        cachedModelsDirectory
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

        guard FileManager.default.fileExists(atPath: path) else {
            markModelNotDownloaded(model)
            AppLogger.info("ModelCatalog", "Model file already missing", details: model.fileName)
            return
        }

        do {
            try FileManager.default.removeItem(atPath: path)
            // Custom models: remove from catalog entirely.
            // Built-in models: revert to notDownloaded.
            if !model.isBuiltIn {
                removeFromCatalog(model)
                clearActiveModelIfNeeded(model.id)
            } else {
                markModelNotDownloaded(model)
            }
            AppLogger.info("ModelCatalog", "Model deleted", details: model.fileName)
        } catch {
            if !FileManager.default.fileExists(atPath: path) {
                markModelNotDownloaded(model)
            }
            AppLogger.error("ModelCatalog", "Failed to delete model", details: error.localizedDescription)
        }
    }

    /// Remove a custom model from the catalog without deleting its file.
    /// Used when a model was added but never downloaded.
    func removeCustomModel(_ model: LocalModel) {
        guard !model.isBuiltIn else { return }
        removeFromCatalog(model)
        AppLogger.info("ModelCatalog", "Custom model removed from catalog", details: model.name)
    }

    private func removeFromCatalog(_ model: LocalModel) {
        models.removeAll { $0.id == model.id }
        modelStates.removeValue(forKey: model.id)
        persistCustomModels()
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
                let candidates = try await resolveCustomModelCandidates(huggingFaceInput: huggingFaceRepo)
                guard let candidate = candidates.first else {
                    throw CatalogError.noCompatibleGGUFFileFound(huggingFaceRepo)
                }
                let model = makeLocalModel(from: candidate)
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

    /// Add a user-selected GGUF candidate to the catalog and start downloading it.
    func addCustomModel(_ candidate: GGUFModelCandidate) {
        let model = makeLocalModel(from: candidate)
        if !models.contains(where: { $0.id == model.id }) {
            models.append(model)
            persistCustomModels()
        }
        downloadModel(model)
    }

    /// Resolve compatible GGUF files for a HuggingFace model id or URL.
    func resolveCustomModelCandidates(huggingFaceInput: String) async throws -> [GGUFModelCandidate] {
        let sourceRepo = try normalizeHuggingFaceRepo(huggingFaceInput)
        let sourceModel = try await fetchHuggingFaceModel(repo: sourceRepo)
        var candidates: [GGUFModelCandidate] = []
        var unsupportedGGUFCount = 0
        var runtimeUnsupportedGGUFCount = 0

        let baseRepos = baseModelRepos(from: sourceModel)
        let referenceRepos = uniqueValues([sourceRepo] + baseRepos)

        let direct = buildGGUFCandidates(
            from: sourceModel,
            repo: sourceRepo,
            sourceRepo: sourceRepo,
            referenceRepos: referenceRepos
        )
        candidates.append(contentsOf: direct.candidates)
        unsupportedGGUFCount += direct.unsupportedCount
        runtimeUnsupportedGGUFCount += direct.runtimeUnsupportedCount

        if candidates.isEmpty {
            let reposToInspect = try await discoverGGUFRepos(
                sourceRepo: sourceRepo,
                referenceRepos: referenceRepos
            )

            for repo in reposToInspect where repo != sourceRepo {
                let model = try? await fetchHuggingFaceModel(repo: repo)
                guard let model else { continue }
                let resolved = buildGGUFCandidates(
                    from: model,
                    repo: repo,
                    sourceRepo: sourceRepo,
                    referenceRepos: referenceRepos
                )
                candidates.append(contentsOf: resolved.candidates)
                unsupportedGGUFCount += resolved.unsupportedCount
                runtimeUnsupportedGGUFCount += resolved.runtimeUnsupportedCount
            }
        }

        let sorted = sortedGGUFCandidates(candidates)

        if sorted.isEmpty {
            if runtimeUnsupportedGGUFCount > 0 {
                throw CatalogError.onlyRuntimeUnsupportedGGUFFilesFound(sourceRepo)
            }
            if unsupportedGGUFCount > 0 {
                throw CatalogError.onlyUnsupportedGGUFFilesFound(sourceRepo)
            }
            throw CatalogError.noCompatibleGGUFFileFound(sourceRepo)
        }

        return Array(sorted.prefix(40))
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

        if let activeModelId,
           modelStates[activeModelId] == .notDownloaded || modelStates[activeModelId] == nil {
            clearActiveModelIfNeeded(activeModelId)
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
            markModelNotDownloaded(model)
            downloadError = error.localizedDescription
            AppLogger.error("ModelCatalog", "Download failed", details: error.localizedDescription)
        }
    }

    private func markModelNotDownloaded(_ model: LocalModel) {
        modelStates[model.id] = .notDownloaded
        clearActiveModelIfNeeded(model.id)
    }

    private func clearActiveModelIfNeeded(_ modelId: String) {
        guard activeModelId == modelId else { return }
        activeModelId = nil
        UserDefaults.standard.removeObject(forKey: DefaultsKey.activeModelId)
    }

    private func makeLocalModel(from candidate: GGUFModelCandidate) -> LocalModel {
        LocalModel(
            id: "custom-\(Self.sanitizedIdentifier(candidate.repo))-\(Self.sanitizedIdentifier(candidate.remoteFileName))",
            name: candidate.modelName,
            fileName: candidate.localFileName,
            downloadURL: candidate.downloadURL,
            sizeBytes: 0,
            description: candidate.description,
            isBuiltIn: false
        )
    }

    /// Fetch HuggingFace model metadata and construct a `LocalModel` for the
    /// first compatible `.gguf` sibling found.
    private func resolveCustomModel(repo: String) async throws -> LocalModel {
        let candidates = try await resolveCustomModelCandidates(huggingFaceInput: repo)
        guard let candidate = candidates.first else {
            throw CatalogError.noCompatibleGGUFFileFound(repo)
        }
        return makeLocalModel(from: candidate)
    }

    private func fetchHuggingFaceModel(repo: String) async throws -> [String: Any] {
        let apiURLString = "https://huggingface.co/api/models/\(repo)"
        guard let apiURL = URL(string: apiURLString) else {
            throw CatalogError.invalidURL(apiURLString)
        }

        let (data, response) = try await URLSession.shared.data(from: apiURL)

        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode != 200 {
            throw CatalogError.huggingFaceAPIFailed(httpResponse.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogError.noGGUFFileFound(repo)
        }

        return json
    }

    private func searchHuggingFaceGGUFModels(term: String) async throws -> [[String: Any]] {
        guard var components = URLComponents(string: "https://huggingface.co/api/models") else {
            throw CatalogError.invalidURL("https://huggingface.co/api/models")
        }
        components.queryItems = [
            URLQueryItem(name: "filter", value: "gguf"),
            URLQueryItem(name: "search", value: term),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "30"),
            URLQueryItem(name: "full", value: "true"),
            URLQueryItem(name: "config", value: "true")
        ]
        guard let url = components.url else {
            throw CatalogError.invalidURL(term)
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode != 200 {
            throw CatalogError.huggingFaceAPIFailed(httpResponse.statusCode)
        }

        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    func normalizeHuggingFaceRepo(_ input: String) throws -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("huggingface.co/") {
            value = "https://\(value)"
        }

        if let url = URL(string: value),
           let host = url.host?.lowercased(),
           host == "huggingface.co" || host.hasSuffix(".huggingface.co") {
            let components = url.pathComponents.filter { $0 != "/" }
            if components.count >= 2 {
                return try validatedHuggingFaceRepo(owner: components[0], name: components[1], input: input)
            }
        }

        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = value.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2 else {
            throw CatalogError.invalidRepositoryInput(input)
        }

        return try validatedHuggingFaceRepo(owner: String(parts[0]), name: String(parts[1]), input: input)
    }

    private func validatedHuggingFaceRepo(owner: String, name: String, input: String) throws -> String {
        guard isValidHuggingFaceRepoComponent(owner),
              isValidHuggingFaceRepoComponent(name),
              owner != ".", owner != "..",
              name != ".", name != ".." else {
            throw CatalogError.invalidRepositoryInput(input)
        }
        return "\(owner)/\(name)"
    }

    private func isValidHuggingFaceRepoComponent(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func discoverGGUFRepos(
        sourceRepo: String,
        referenceRepos: [String]
    ) async throws -> [String] {
        var repos: [String] = []
        for repo in referenceRepos {
            repos.append(contentsOf: generatedGGUFRepoCandidates(for: repo))
        }

        let searchTerms = uniqueValues(referenceRepos.map { repoName($0) })
        let normalizedTerms = searchTerms.map(Self.normalizedForSearch)

        for term in searchTerms {
            let results = (try? await searchHuggingFaceGGUFModels(term: term)) ?? []
            for result in results {
                guard let repo = modelId(from: result), repo != sourceRepo else { continue }
                let tags = result["tags"] as? [String] ?? []
                let hasExactBase = referenceRepos.contains { reference in
                    tags.contains("base_model:\(reference)") ||
                    tags.contains("base_model:quantized:\(reference)")
                }
                let normalizedRepoName = Self.normalizedForSearch(repoName(repo))
                let hasStrongNameMatch = normalizedTerms.contains { term in
                    !term.isEmpty && normalizedRepoName.contains(term)
                }

                if hasExactBase || hasStrongNameMatch {
                    repos.append(repo)
                }
            }
        }

        return uniqueValues(repos)
    }

    func generatedGGUFRepoCandidates(for repo: String) -> [String] {
        let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return [] }
        let owner = parts[0]
        let name = parts[1]
        var candidates = [
            "\(owner)/\(name)-GGUF",
            "\(owner)/\(name)-gguf"
        ]

        if name.hasSuffix("-unquantized") {
            let stem = String(name.dropLast("-unquantized".count))
            candidates.append("\(owner)/\(stem)-gguf")
            candidates.append("\(owner)/\(stem)-GGUF")
        }

        if name.contains("-qat-q4_0-unquantized") {
            let stem = name.replacingOccurrences(of: "-qat-q4_0-unquantized", with: "-qat-q4_0")
            candidates.append("\(owner)/\(stem)-gguf")
            candidates.append("\(owner)/\(stem)-GGUF")
        }

        return uniqueValues(candidates)
    }

    struct GGUFBuildResult {
        let candidates: [GGUFModelCandidate]
        let unsupportedCount: Int
        let runtimeUnsupportedCount: Int
    }

    func buildGGUFCandidates(
        from model: [String: Any],
        repo: String,
        sourceRepo: String,
        referenceRepos: [String]
    ) -> GGUFBuildResult {
        let siblings = model["siblings"] as? [[String: Any]] ?? []
        let tags = model["tags"] as? [String] ?? []
        let downloads = model["downloads"] as? Int ?? 0
        let sortRank = repositorySortRank(
            repo: repo,
            sourceRepo: sourceRepo,
            referenceRepos: referenceRepos,
            tags: tags
        )
        let sourceKind = sourceKind(
            repo: repo,
            sourceRepo: sourceRepo,
            tags: tags
        )

        var unsupportedCount = 0
        var runtimeUnsupportedCount = 0
        let candidates: [GGUFModelCandidate] = siblings.compactMap { sibling in
            guard let remoteFileName = sibling["rfilename"] as? String,
                  remoteFileName.lowercased().hasSuffix(".gguf") else {
                return nil
            }

            guard isSupportedMainGGUFFile(remoteFileName) else {
                unsupportedCount += 1
                return nil
            }

            guard isSupportedByBundledRuntime(repo: repo, remoteFileName: remoteFileName, tags: tags) else {
                runtimeUnsupportedCount += 1
                return nil
            }

            let fileRank = Self.ggufFileRank(remoteFileName)
            let localFileName = safeLocalFileName(repo: repo, remoteFileName: remoteFileName)
            let downloadURL = huggingFaceDownloadURL(repo: repo, remoteFileName: remoteFileName)
            let quantization = Self.quantizationLabel(from: remoteFileName)
            let name = [repoName(repo), quantization].filter { !$0.isEmpty }.joined(separator: " ")

            return GGUFModelCandidate(
                repo: repo,
                remoteFileName: remoteFileName,
                localFileName: localFileName,
                downloadURL: downloadURL,
                modelName: name,
                description: "Custom GGUF from \(repo)",
                sourceKind: sourceKind,
                sortRank: sortRank,
                fileRank: fileRank,
                downloadCount: downloads
            )
        }

        return GGUFBuildResult(
            candidates: candidates,
            unsupportedCount: unsupportedCount,
            runtimeUnsupportedCount: runtimeUnsupportedCount
        )
    }

    func sortedGGUFCandidates(_ candidates: [GGUFModelCandidate]) -> [GGUFModelCandidate] {
        var seen = Set<String>()
        return candidates
            .filter { seen.insert($0.id).inserted }
            .sorted {
                if $0.sortRank != $1.sortRank { return $0.sortRank < $1.sortRank }
                if $0.fileRank != $1.fileRank { return $0.fileRank < $1.fileRank }
                if $0.downloadCount != $1.downloadCount { return $0.downloadCount > $1.downloadCount }
                return $0.id < $1.id
            }
    }

    private func repositorySortRank(
        repo: String,
        sourceRepo: String,
        referenceRepos: [String],
        tags: [String]
    ) -> Int {
        let sourceOwner = repoOwner(sourceRepo)
        let owner = repoOwner(repo)
        let hasSourceQuantizedTag = tags.contains("base_model:quantized:\(sourceRepo)")
        let hasSourceTag = tags.contains("base_model:\(sourceRepo)")

        if repo == sourceRepo { return 0 }
        if owner == sourceOwner { return 10 }
        if owner == "ggml-org" && (hasSourceQuantizedTag || hasSourceTag) { return 20 }
        if hasSourceQuantizedTag { return 30 }
        if hasSourceTag { return 40 }

        for reference in referenceRepos where reference != sourceRepo {
            let hasReferenceQuantizedTag = tags.contains("base_model:quantized:\(reference)")
            let hasReferenceTag = tags.contains("base_model:\(reference)")
            if owner == "ggml-org" && (hasReferenceQuantizedTag || hasReferenceTag) { return 50 }
            if hasReferenceQuantizedTag { return 60 }
            if hasReferenceTag { return 70 }
        }

        if owner == "ggml-org" { return 80 }
        if let index = Self.trustedGGUFOwners.firstIndex(of: owner) {
            return 90 + index
        }
        return 200
    }

    private func sourceKind(
        repo: String,
        sourceRepo: String,
        tags: [String]
    ) -> GGUFSourceKind {
        let owner = repoOwner(repo)
        if repo == sourceRepo { return .direct }
        if owner == repoOwner(sourceRepo) { return .sameOwner }
        if owner == "ggml-org" { return .ggml }
        if tags.contains("base_model:\(sourceRepo)") ||
            tags.contains("base_model:quantized:\(sourceRepo)") ||
            Self.trustedGGUFOwners.contains(owner) {
            return .trusted
        }
        return .community
    }

    func baseModelRepos(from model: [String: Any]) -> [String] {
        var repos: [String] = []
        let tags = model["tags"] as? [String] ?? []
        for tag in tags where tag.hasPrefix("base_model:") {
            var value = String(tag.dropFirst("base_model:".count))
            if value.hasPrefix("quantized:") {
                value = String(value.dropFirst("quantized:".count))
            }
            if value.hasPrefix("finetune:") {
                continue
            }
            if value.split(separator: "/").count == 2 {
                repos.append(value)
            }
        }

        if let cardData = model["cardData"] as? [String: Any] {
            if let baseModel = cardData["base_model"] as? String,
               baseModel.split(separator: "/").count == 2 {
                repos.append(baseModel)
            } else if let baseModels = cardData["base_model"] as? [String] {
                repos.append(contentsOf: baseModels.filter { $0.split(separator: "/").count == 2 })
            }
        }

        return uniqueValues(repos)
    }

    private func modelId(from model: [String: Any]) -> String? {
        model["modelId"] as? String ?? model["id"] as? String
    }

    private func repoOwner(_ repo: String) -> String {
        repo.split(separator: "/", maxSplits: 1).first.map(String.init) ?? repo
    }

    private func repoName(_ repo: String) -> String {
        repo.split(separator: "/", maxSplits: 1).last.map(String.init) ?? repo
    }

    private func uniqueValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func isSupportedMainGGUFFile(_ fileName: String) -> Bool {
        let lowercased = fileName.lowercased()
        guard lowercased.hasSuffix(".gguf") else { return false }
        if lowercased.contains("mmproj") { return false }
        if lowercased.hasPrefix("mtp/") { return false }
        if lowercased.contains("/mtp/") { return false }
        if lowercased.hasPrefix("mtp-") { return false }
        if lowercased.contains("-mtp") { return false }
        if Self.isSplitGGUFFile(lowercased) { return false }
        return true
    }

    private func isSupportedByBundledRuntime(repo: String, remoteFileName: String, tags: [String]) -> Bool {
        let markers = ([repo, remoteFileName] + tags).joined(separator: " ").lowercased()
        if containsRuntimeMarker(markers, pattern: #"\bgemma-4\b"#) { return false }
        if containsRuntimeMarker(markers, pattern: #"\bgemma4\b"#) { return false }
        if containsRuntimeMarker(markers, pattern: #"\bgpt-oss\b"#) { return false }
        return true
    }

    private func containsRuntimeMarker(_ markers: String, pattern: String) -> Bool {
        markers.range(of: pattern, options: .regularExpression) != nil
    }

    private func safeLocalFileName(repo: String, remoteFileName: String) -> String {
        let safeRemote = remoteFileName
            .replacingOccurrences(of: "/", with: "--")
            .replacingOccurrences(of: ":", with: "-")
        return "\(Self.sanitizedIdentifier(repo))--\(safeRemote)"
    }

    private func huggingFaceDownloadURL(repo: String, remoteFileName: String) -> String {
        let encodedFile = remoteFileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? remoteFileName
        return "https://huggingface.co/\(repo)/resolve/main/\(encodedFile)"
    }

    private static let trustedGGUFOwners = [
        "google",
        "Qwen",
        "unsloth",
        "lmstudio-community",
        "bartowski",
        "MaziyarPanahi",
        "mradermacher",
        "QuantFactory",
        "TheBloke",
        "hugging-quants"
    ]

    private static func sanitizedIdentifier(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    private static func normalizedForSearch(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private static func isSplitGGUFFile(_ lowercasedFileName: String) -> Bool {
        lowercasedFileName.range(
            of: #"-\d{5}-of-\d{5}\.gguf$"#,
            options: .regularExpression
        ) != nil
    }

    private static func ggufFileRank(_ fileName: String) -> Int {
        let lowercased = fileName.lowercased()
        let preferred = [
            "q4_k_m", "q4_0", "q5_k_m", "q5_k_s", "q6_k", "q8_0", "bf16", "f16", "q3_k_m", "q2_k"
        ]
        for (index, marker) in preferred.enumerated() where lowercased.contains(marker) {
            return index
        }
        return 100
    }

    private static func quantizationLabel(from fileName: String) -> String {
        let lowercased = fileName.lowercased()
        let labels = [
            "Q4_K_M", "Q4_0", "Q5_K_M", "Q5_K_S", "Q6_K", "Q8_0", "BF16", "F16", "Q3_K_M", "Q2_K"
        ]
        return labels.first { lowercased.contains($0.lowercased()) } ?? ""
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
