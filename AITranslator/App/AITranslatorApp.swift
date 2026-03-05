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
                .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
                    openSettingsWindow()
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

            CommandGroup(replacing: .pasteboard) {
                Button(NSLocalizedString("action.paste", comment: "Paste")) {
                    if OCRService.clipboardContainsImage(), let image = OCRService.imageFromClipboard() {
                        // Image in clipboard — run OCR
                        Task { await translatorViewModel.processImage(image) }
                    } else {
                        // Text in clipboard — standard paste
                        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                    }
                }
                .keyboardShortcut("v", modifiers: .command)

                Button(NSLocalizedString("action.copy", comment: "Copy")) {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("c", modifiers: .command)

                Button(NSLocalizedString("action.cut", comment: "Cut")) {
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("x", modifiers: .command)

                Button(NSLocalizedString("action.select_all", comment: "Select All")) {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("a", modifiers: .command)
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

    private var settingsWindow: NSWindow?

    private func openSettingsWindow() {
        // If settings window already exists and visible, just bring to front
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        // Also check if SwiftUI already opened one
        if let window = NSApp.windows.first(where: {
            $0.title == NSLocalizedString("settings.title", comment: "")
        }) {
            window.makeKeyAndOrderFront(nil)
            return
        }

        // Create a new settings window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = NSLocalizedString("settings.title", comment: "Settings")
        window.contentView = NSHostingView(rootView:
            SettingsView()
                .environmentObject(settingsViewModel)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }
}
