import SwiftUI

/// Language selector with a popover containing search and grouped list
struct LanguageSelectorView: View {
    @Binding var selectedLanguage: Language
    let showAutoDetect: Bool
    /// When source is Auto Detect, this shows the detected language
    var detectedLanguage: Language? = nil
    @State private var searchText = ""
    @State private var isPresented = false

    /// Display language: detected if auto, otherwise selected
    private var displayLanguage: Language {
        if selectedLanguage.code == "auto", let detected = detectedLanguage {
            return detected
        }
        return selectedLanguage
    }

    /// Whether to show "(auto)" suffix
    private var isAutoDetected: Bool {
        selectedLanguage.code == "auto" && detectedLanguage != nil
    }

    var body: some View {
        Button(action: { isPresented.toggle() }) {
            HStack(spacing: 6) {
                Text(displayLanguage.flag)
                if isAutoDetected {
                    Text("\(displayLanguage.name)")
                        .fontWeight(.medium)
                    Text("(\(NSLocalizedString("language.auto_short", comment: "auto")))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(selectedLanguage.name)
                        .fontWeight(.medium)
                }
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            LanguagePopoverContent(
                selectedLanguage: $selectedLanguage,
                showAutoDetect: showAutoDetect,
                isPresented: $isPresented
            )
        }
    }
}

/// Popover content with search field and language list
private struct LanguagePopoverContent: View {
    @Binding var selectedLanguage: Language
    let showAutoDetect: Bool
    @Binding var isPresented: Bool
    @State private var searchText = ""

    private static let recentKey = "recentLanguageCodes"
    private static let maxRecent = 3

    private var recentLanguages: [Language] {
        guard searchText.isEmpty else { return [] }
        let codes = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
        return codes.compactMap { code in
            LanguageList.find(byCode: code)
        }
    }

    private var filteredLanguages: [Language] {
        let all = LanguageList.all
        if searchText.isEmpty {
            return all
        }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.localizedName.localizedCaseInsensitiveContains(searchText) ||
            $0.code.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func trackLanguage(_ code: String) {
        guard code != "auto" else { return }
        var codes = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
        codes.removeAll { $0 == code }
        codes.insert(code, at: 0)
        if codes.count > Self.maxRecent {
            codes = Array(codes.prefix(Self.maxRecent))
        }
        UserDefaults.standard.set(codes, forKey: Self.recentKey)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(NSLocalizedString("language.search", comment: "Search..."), text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)

            Divider()

            // Language list
            ScrollViewReader { proxy in
                List {
                    // Auto Detect option
                    if showAutoDetect && (searchText.isEmpty ||
                        "auto detect".localizedCaseInsensitiveContains(searchText) ||
                        NSLocalizedString("language.auto_detect", comment: "")
                            .localizedCaseInsensitiveContains(searchText)) {
                        languageRow(Language.autoDetect)
                            .id("auto")
                    }

                    // Recent languages
                    if !recentLanguages.isEmpty {
                        Section(header: Text(NSLocalizedString("language.recent", comment: "Recent"))
                            .font(.caption)
                            .foregroundStyle(.secondary)) {
                            ForEach(recentLanguages) { language in
                                languageRow(language)
                            }
                        }
                    }

                    // All languages
                    Section(header: recentLanguages.isEmpty ? nil :
                        Text(NSLocalizedString("language.all", comment: "All Languages"))
                            .font(.caption)
                            .foregroundStyle(.secondary)) {
                        ForEach(filteredLanguages) { language in
                            languageRow(language)
                        }
                    }
                }
                .listStyle(.plain)
                .onAppear {
                    proxy.scrollTo(selectedLanguage.code, anchor: .center)
                }
            }
        }
        .frame(width: 260, height: 350)
    }

    @ViewBuilder
    private func languageRow(_ language: Language) -> some View {
        Button(action: {
            trackLanguage(language.code)
            selectedLanguage = language
            isPresented = false
        }) {
            HStack(spacing: 10) {
                Text(language.flag)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 1) {
                    Text(language.name)
                        .fontWeight(selectedLanguage.code == language.code ? .semibold : .regular)
                    if language.name != language.localizedName && language.code != "auto" {
                        Text(language.localizedName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if selectedLanguage.code == language.code {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                        .fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(language.code)
    }
}
