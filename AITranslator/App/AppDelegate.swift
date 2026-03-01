import Cocoa
import SwiftUI
import Carbon.HIToolbox

/// AppDelegate handles global hotkey registration and menu bar status item.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotKeyRef: EventHotKeyRef?
    /// Shared ViewModels — injected from AITranslatorApp
    var settingsViewModel: SettingsViewModel?
    var translatorViewModel: TranslatorViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        requestAccessibility()
        setupGlobalHotkey()
    }

    private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        print("[Hotkey] Accessibility trusted: \(trusted)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
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

    // MARK: - Global Hotkey (⌘⇧C via Carbon API)

    private func setupGlobalHotkey() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x5452_4E53), // "TRNS"
                                      id: 1)

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        let handlerPtr = UnsafeMutablePointer<AppDelegate>.allocate(capacity: 1)
        handlerPtr.initialize(to: self)

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                let delegate = userData.assumingMemoryBound(to: AppDelegate.self).pointee
                // Read selected text NOW, before our app takes focus
                let selectedText = AppDelegate.readSelectedText()
                let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
                let text = selectedText ?? clipboard
                print("[Hotkey] Captured — selected: \(selectedText != nil ? selectedText!.prefix(30) : "nil"), clipboard: \(clipboard.prefix(30))")
                DispatchQueue.main.async {
                    delegate.handleHotkey(text: text)
                }
                return noErr
            },
            1, &eventType, handlerPtr, nil
        )

        let modifiers = UInt32(cmdKey | shiftKey)
        let keyCode = UInt32(kVK_ANSI_C)

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                          GetApplicationEventTarget(), 0, &ref)

        if status == noErr {
            hotKeyRef = ref
            print("[Hotkey] ⌘⇧C registered successfully")
        } else {
            print("[Hotkey] Failed to register ⌘⇧C hotkey: \(status)")
        }
    }

    // MARK: - Hotkey Action

    func handleHotkey(text: String) {
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

    /// Read selected text from the focused element via Accessibility API
    /// Called from callback thread (not main) to capture before focus changes
    static func readSelectedText() -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let systemWide = AXUIElementCreateSystemWide()

        var focusedApp: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success else { return nil }

        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedApp as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else { return nil }

        var selectedText: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedElement as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedText) == .success else { return nil }

        let text = selectedText as? String
        return (text?.isEmpty == false) ? text : nil
    }
}
