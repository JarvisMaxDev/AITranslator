import SwiftUI

@main
struct AITranslatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var settingsViewModel = SettingsViewModel()
    @StateObject private var translatorViewModel: TranslatorViewModel

    init() {
        let settings = SettingsViewModel()
        _settingsViewModel = StateObject(wrappedValue: settings)
        _translatorViewModel = StateObject(wrappedValue: TranslatorViewModel(settingsViewModel: settings))
    }

    var body: some Scene {
        WindowGroup {
            TranslatorView()
                .environmentObject(translatorViewModel)
                .environmentObject(settingsViewModel)
                .frame(minWidth: 700, minHeight: 500)
                .onOpenURL { url in
                    handleOAuthCallback(url: url)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 900, height: 600)

        Settings {
            SettingsView()
                .environmentObject(settingsViewModel)
        }
    }

    private func handleOAuthCallback(url: URL) {
        guard url.scheme == "aitranslator" else { return }
        Task {
            await settingsViewModel.handleOAuthCallback(url: url)
        }
    }
}
