import SwiftUI

/// Settings section for managing local GGUF models.
///
/// Shows a list of catalog models with their download/active states,
/// allows downloading, deleting, selecting models, and adding custom
/// models from HuggingFace.
struct LocalModelSettingsView: View {
    @ObservedObject var catalog: ModelCatalog
    @State private var customRepoInput = ""
    @State private var showCustomModelField = false

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
                HStack(spacing: 8) {
                    TextField("owner/repo", text: $customRepoInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)

                    Button(NSLocalizedString("action.download", comment: "Download")) {
                        guard !customRepoInput.isEmpty else { return }
                        catalog.addCustomModel(huggingFaceRepo: customRepoInput)
                        customRepoInput = ""
                        showCustomModelField = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(customRepoInput.isEmpty)

                    Button(NSLocalizedString("action.cancel", comment: "Cancel")) {
                        showCustomModelField = false
                        customRepoInput = ""
                    }
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
        let state = catalog.modelStates[model.id] ?? .notDownloaded

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
            Button(NSLocalizedString("action.download", comment: "Download")) {
                catalog.downloadModel(model)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

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
                    catalog.selectModel(model)
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
}
