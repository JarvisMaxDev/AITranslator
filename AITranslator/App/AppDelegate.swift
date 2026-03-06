import Cocoa
import SwiftUI

/// Thin coordinator — delegates hotkey, status bar, and window management
/// to dedicated services.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    /// Shared ViewModels — injected from AITranslatorApp
    var settingsViewModel: SettingsViewModel?
    var translatorViewModel: TranslatorViewModel?

    private let hotkeyService = HotkeyService()
    private let statusBar = StatusBarController()
    private var settingsWindow: NSWindow?
    private var consoleWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        requestAccessibility()
        startHotkey()

        // Listen for settings open requests from TranslatorView gear button
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettings),
            name: .openSettings,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyService.stop()
    }

    // MARK: - Setup

    private func setupStatusBar() {
        statusBar.setup(actions: .init(
            showTranslator: { [weak self] in self?.showMainWindow() },
            openSettings: { [weak self] in self?.openSettings() },
            openConsole: { [weak self] in self?.openConsole() },
            quit: { NSApp.terminate(nil) }
        ))
    }

    private func startHotkey() {
        hotkeyService.start { [weak self] text in
            self?.handleCapturedText(text)
        }
    }

    // MARK: - Hotkey Handler

    private func handleCapturedText(_ text: String) {
        // Show main window
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title.contains("Translator") }) {
            window.makeKeyAndOrderFront(nil)
        }

        // Set text and auto-translate
        if let vm = translatorViewModel, !text.isEmpty {
            vm.sourceText = text
            Task {
                await vm.translate()
            }
        }
    }

    // MARK: - Window Management

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title.contains("Translator") || $0.isKeyWindow }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        guard let vm = settingsViewModel else { return }

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
                .environmentObject(vm)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    private func openConsole() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = consoleWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = NSLocalizedString("menu.console", comment: "Console")
        window.contentView = NSHostingView(rootView: ConsoleView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        consoleWindow = window
    }

    // MARK: - Accessibility

    private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        AppLogger.shared.info("Accessibility", "Trusted: \(trusted)")

        if !trusted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                let rechecked = AXIsProcessTrusted()
                AppLogger.shared.info("Accessibility", "Re-check after prompt: \(rechecked)")
                if !rechecked {
                    self?.showAccessibilityAlert()
                }
            }
        }
    }

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("accessibility.title", comment: "Accessibility Access Required")
        alert.informativeText = NSLocalizedString("accessibility.message", comment: "AI Translator needs Accessibility access to capture selected text with the global hotkey. Please add it in System Settings > Privacy & Security > Accessibility.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("accessibility.open_settings", comment: "Open Settings"))
        alert.addButton(withTitle: NSLocalizedString("accessibility.later", comment: "Later"))

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
