import SwiftUI

/// ViewModel for the popup translator window
@MainActor
final class PopupViewModel: ObservableObject {
    @Published var sourceText: String = ""
    @Published var translatedText: String = ""
    @Published var isTranslating: Bool = false

    func dismiss() {
        NSApp.keyWindow?.close()
    }
}
