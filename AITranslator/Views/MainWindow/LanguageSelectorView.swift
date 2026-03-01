import SwiftUI

/// Language selector with a popover containing search and grouped list
struct LanguageSelectorView: View {
    @Binding var selectedLanguage: Language
    let showAutoDetect: Bool
    @State private var searchText = ""
    @State private var isPresented = false

    var body: some View {
        Button(action: { isPresented.toggle() }) {
            HStack(spacing: 6) {
                Text(selectedLanguage.flag)
                Text(selectedLanguage.name)
                    .fontWeight(.medium)
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

                    // All languages
                    ForEach(filteredLanguages) { language in
                        languageRow(language)
                    }
                }
                .listStyle(.plain)
                .onAppear {
                    // Scroll to selected language
                    proxy.scrollTo(selectedLanguage.code, anchor: .center)
                }
            }
        }
        .frame(width: 260, height: 350)
    }

    @ViewBuilder
    private func languageRow(_ language: Language) -> some View {
        Button(action: {
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
