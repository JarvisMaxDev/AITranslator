import SwiftUI

/// Language selector dropdown with search functionality
struct LanguageSelectorView: View {
    @Binding var selectedLanguage: Language
    let showAutoDetect: Bool
    @State private var searchText = ""
    @State private var isExpanded = false

    private var filteredLanguages: [Language] {
        let languages = showAutoDetect
            ? [Language.autoDetect] + LanguageList.all
            : LanguageList.all

        if searchText.isEmpty {
            return languages
        }

        return languages.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.localizedName.localizedCaseInsensitiveContains(searchText) ||
            $0.code.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        Menu {
            // Search field (using TextField in menu is limited, so we use a filter approach)
            ForEach(filteredLanguages) { language in
                Button(action: {
                    selectedLanguage = language
                }) {
                    HStack {
                        Text(language.flag)
                        Text(language.name)
                        if language.name != language.localizedName && language.code != "auto" {
                            Text("(\(language.localizedName))")
                                .foregroundStyle(.secondary)
                        }
                        if selectedLanguage.code == language.code {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
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
        .menuStyle(.button)
        .buttonStyle(.plain)
    }
}
