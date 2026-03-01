import Cocoa
import SwiftUI
import Carbon.HIToolbox

/// AppDelegate handles global hotkey registration and menu bar status item.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popupWindow: NSWindow?
    private var popupHostingController: NSHostingController<AnyView>?
    private var lastControlCTime: Date?
    private var eventMonitor: Any?
    /// Shared SettingsViewModel — injected from AITranslatorApp after launch
    var settingsViewModel: SettingsViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        requestAccessibilityIfNeeded()
        setupGlobalHotkey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Accessibility Permissions

    private func requestAccessibilityIfNeeded() {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        if !trusted {
            print("[Hotkey] Accessibility not granted — global hotkeys will not work until enabled in System Settings.")
        }
    }

    // MARK: - Status Bar Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "AI Translator")
            button.action = #selector(statusItemClicked)
            button.target = self
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: NSLocalizedString("menu.show_translator", comment: "Show Translator"), action: #selector(showMainWindow), keyEquivalent: "t"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: NSLocalizedString("menu.settings", comment: "Settings..."), action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: NSLocalizedString("menu.quit", comment: "Quit"), action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func statusItemClicked() {
        showMainWindow()
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title.contains("Translator") || $0.isKeyWindow }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Global Hotkey (Double ⌘C)

    private func setupGlobalHotkey() {
        // Monitor global key events for double ⌘C
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleGlobalKeyEvent(event)
        }
    }

    private func handleGlobalKeyEvent(_ event: NSEvent) {
        // Check for ⌘C (keyCode 8 = 'c', modifierFlags contains .command)
        guard event.keyCode == 8,
              event.modifierFlags.contains(.command) else {
            lastControlCTime = nil
            return
        }

        let now = Date()
        if let lastTime = lastControlCTime,
           now.timeIntervalSince(lastTime) < 0.4 {
            // Double Ctrl+C detected
            lastControlCTime = nil
            DispatchQueue.main.async { [weak self] in
                self?.showPopupTranslator()
            }
        } else {
            lastControlCTime = now
        }
    }

    // MARK: - Popup Translator

    private func showPopupTranslator() {
        // Read from clipboard (first Ctrl+C already copied the text)
        let clipboardText = NSPasteboard.general.string(forType: .string) ?? ""

        if let existing = popupWindow, existing.isVisible {
            existing.close()
        }

        // Use shared SettingsViewModel, or create one as fallback
        let settingsVM = settingsViewModel ?? SettingsViewModel()
        let translatorVM = TranslatorViewModel(settingsViewModel: settingsVM)
        translatorVM.sourceText = clipboardText

        let popupView = AnyView(
            PopupTranslatorView()
                .environmentObject(translatorVM)
                .environmentObject(settingsVM)
        )

        let controller = NSHostingController(rootView: popupView)
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 380),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.center()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        popupWindow = window
        popupHostingController = controller

        // Auto-translate if there's text
        if !clipboardText.isEmpty {
            Task {
                await translatorVM.translate()
            }
        }
    }
}
