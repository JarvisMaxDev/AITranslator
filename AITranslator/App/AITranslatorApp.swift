import SwiftUI

@main
struct AITranslatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var settingsViewModel = SettingsViewModel()
    @StateObject private var translatorViewModel: TranslatorViewModel

    init() {
        let settings = SettingsViewModel()
        _settingsViewModel = StateObject(wrappedValue: settings)
        let translator = TranslatorViewModel(settingsViewModel: settings)
        _translatorViewModel = StateObject(wrappedValue: translator)
        // Share ViewModels with AppDelegate for hotkey
        appDelegate.settingsViewModel = settings
        appDelegate.translatorViewModel = translator
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
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button(NSLocalizedString("action.undo", comment: "Undo")) {
                    translatorViewModel.undo()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!translatorViewModel.canUndo)

                Button(NSLocalizedString("action.redo", comment: "Redo")) {
                    translatorViewModel.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!translatorViewModel.canRedo)
            }
        }

        Window(NSLocalizedString("settings.title", comment: "Settings"), id: "settings") {
            SettingsView()
                .environmentObject(settingsViewModel)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    private func handleOAuthCallback(url: URL) {
        guard url.scheme == "aitranslator" else { return }
        Task {
            await settingsViewModel.handleOAuthCallback(url: url)
        }
    }
}
