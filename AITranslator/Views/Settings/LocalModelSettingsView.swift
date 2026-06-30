import SwiftUI

/// Settings section for managing local GGUF models.
///
/// Shows a list of catalog models with their download/active states,
/// allows downloading, deleting, selecting models, and adding custom
/// models from HuggingFace.
struct LocalModelSettingsView: View {
    @ObservedObject var catalog: ModelCatalog
    let selectedModelId: String?
    let onUseModel: (LocalModel) -> Void

    @State private var customRepoInput = ""
    @State private var showCustomModelField = false
    @State private var isResolvingCustomModel = false
    @State private var ggufCandidates: [GGUFModelCandidate] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section header
            HStack {
                Label {
                    Text(NSLocalizedString("settings.local_models", comment: "Local Models"))
                        .font(.headline)
                } icon: {
                    Image(systemName: "cpu")
                }

                Spacer()

                Button(action: { showCustomModelField.toggle() }) {
                    Label(
                        NSLocalizedString("settings.add_from_hf", comment: "Add from HuggingFace"),
                        systemImage: "plus"
                    )
                }
                .controlSize(.small)
            }

            Text(NSLocalizedString("settings.local_models_description", comment: "Download AI models for offline translation. Larger models produce better results but need more disk space and RAM."))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Custom model input
            if showCustomModelField {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("owner/repo", text: $customRepoInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 300)

                        Button(NSLocalizedString("settings.find_gguf", comment: "Find GGUF files")) {
                            guard !customRepoInput.isEmpty else { return }
                            resolveGGUFCandidates()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(customRepoInput.isEmpty || isResolvingCustomModel)

                        Button(NSLocalizedString("action.cancel", comment: "Cancel")) {
                            showCustomModelField = false
                            customRepoInput = ""
                            ggufCandidates = []
                        }
                    }

                    if isResolvingCustomModel {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(NSLocalizedString("settings.searching_gguf", comment: "Searching GGUF files..."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !ggufCandidates.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(NSLocalizedString("settings.compatible_gguf", comment: "Compatible GGUF files"))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ForEach(ggufCandidates) { candidate in
                                ggufCandidateRow(candidate)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .onChange(of: customRepoInput) { _, _ in
                    ggufCandidates = []
                    catalog.downloadError = nil
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
            }

            // Error display
            if let error = catalog.downloadError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button(action: { catalog.downloadError = nil }) {
                        Image(systemName: "xmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(.red.opacity(0.1)))
            }

            // Model list
            VStack(spacing: 8) {
                ForEach(catalog.models) { model in
                    modelRow(model)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Model Row

    @ViewBuilder
    private func modelRow(_ model: LocalModel) -> some View {
        let state = displayState(for: model)

        HStack(spacing: 12) {
            // Status indicator
            statusIcon(for: state)
                .frame(width: 24, height: 24)

            // Model info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.system(.body, weight: .medium))

                    if !model.isBuiltIn {
                        Text("Custom")
                            .font(.system(size: 9, weight: .bold))
                            .textCase(.uppercase)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.purple.opacity(0.15)))
                            .foregroundStyle(.purple)
                    }
                }

                HStack(spacing: 8) {
                    Text(model.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if model.sizeBytes > 0 {
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(ModelCatalog.formatFileSize(model.sizeBytes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Actions
            actionButtons(for: model, state: state)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(state == .active ? Color.blue.opacity(0.05) : Color.clear)
        )
    }

    // MARK: - Status Icon

    private func displayState(for model: LocalModel) -> ModelState {
        let state = catalog.modelStates[model.id] ?? .notDownloaded
        guard let selectedModelId else { return state }

        switch state {
        case .downloaded, .active:
            return model.id == selectedModelId ? .active : .downloaded
        case .notDownloaded, .downloading:
            return state
        }
    }

    @ViewBuilder
    private func statusIcon(for state: ModelState) -> some View {
        switch state {
        case .notDownloaded:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .downloading:
            ProgressView()
                .controlSize(.small)
        case .downloaded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .active:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.blue)
        }
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private func actionButtons(for model: LocalModel, state: ModelState) -> some View {
        switch state {
        case .notDownloaded:
            HStack(spacing: 6) {
                Button(NSLocalizedString("action.download", comment: "Download")) {
                    catalog.downloadModel(model)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if !model.isBuiltIn {
                    Button(action: { catalog.removeCustomModel(model) }) {
                        Image(systemName: "trash")
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }

        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 80)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 36)
                Button(action: { catalog.cancelDownload() }) {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

        case .downloaded:
            HStack(spacing: 6) {
                Button(NSLocalizedString("settings.use", comment: "Use")) {
                    onUseModel(model)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: { catalog.deleteModel(model) }) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
            }

        case .active:
            HStack(spacing: 6) {
                Text(NSLocalizedString("settings.active", comment: "Active"))
                    .font(.system(size: 11, weight: .bold))
                    .textCase(.uppercase)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.blue.opacity(0.15)))
                    .foregroundStyle(.blue)

                Button(action: { catalog.deleteModel(model) }) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - GGUF Resolution

    private func resolveGGUFCandidates() {
        let input = customRepoInput
        isResolvingCustomModel = true
        ggufCandidates = []
        catalog.downloadError = nil

        Task { @MainActor in
            do {
                let candidates = try await catalog.resolveCustomModelCandidates(huggingFaceInput: input)
                guard showCustomModelField && customRepoInput == input else {
                    isResolvingCustomModel = false
                    return
                }
                ggufCandidates = candidates
            } catch {
                guard showCustomModelField && customRepoInput == input else {
                    isResolvingCustomModel = false
                    return
                }
                catalog.downloadError = error.localizedDescription
            }
            isResolvingCustomModel = false
        }
    }

    private func ggufCandidateRow(_ candidate: GGUFModelCandidate) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(candidate.repo)
                        .font(.system(.caption, weight: .medium))

                    Text(sourceKindLabel(candidate.sourceKind))
                        .font(.system(size: 9, weight: .bold))
                        .textCase(.uppercase)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(sourceKindColor(candidate.sourceKind).opacity(0.15)))
                        .foregroundStyle(sourceKindColor(candidate.sourceKind))
                }

                Text(candidate.remoteFileName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button(NSLocalizedString("action.download", comment: "Download")) {
                catalog.addCustomModel(candidate)
                customRepoInput = ""
                ggufCandidates = []
                showCustomModelField = false
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func sourceKindLabel(_ kind: GGUFSourceKind) -> String {
        switch kind {
        case .direct:
            return NSLocalizedString("settings.gguf_source.direct", comment: "Direct")
        case .sameOwner:
            return NSLocalizedString("settings.gguf_source.same_owner", comment: "Same owner")
        case .ggml:
            return NSLocalizedString("settings.gguf_source.ggml", comment: "GGML")
        case .trusted:
            return NSLocalizedString("settings.gguf_source.trusted", comment: "Trusted")
        case .community:
            return NSLocalizedString("settings.gguf_source.community", comment: "Community")
        }
    }

    private func sourceKindColor(_ kind: GGUFSourceKind) -> Color {
        switch kind {
        case .direct, .sameOwner:
            return .blue
        case .ggml, .trusted:
            return .green
        case .community:
            return .orange
        }
    }
}
