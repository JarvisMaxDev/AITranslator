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
        setupGlobalHotkey()
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
                DispatchQueue.main.async {
                    delegate.handleHotkey()
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

    func handleHotkey() {
        // Remember current clipboard to detect change
        let previousClipboard = NSPasteboard.general.changeCount

        // Step 1: Simulate ⌘C via AppleScript (more reliable than CGEvent)
        simulateCopy()

        // Step 2: Wait for clipboard to update, then show window with translation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            let clipboardText: String
            if NSPasteboard.general.changeCount != previousClipboard {
                // Clipboard changed — use new content
                clipboardText = NSPasteboard.general.string(forType: .string) ?? ""
            } else {
                // Clipboard didn't change — use existing content
                clipboardText = NSPasteboard.general.string(forType: .string) ?? ""
            }

            // Show main window
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.title.contains("Translator") }) {
                window.makeKeyAndOrderFront(nil)
            }

            // Set clipboard text and auto-translate
            if let vm = self?.translatorViewModel, !clipboardText.isEmpty {
                vm.sourceText = clipboardText
                Task {
                    await vm.translate()
                }
            }
        }
    }

    /// Simulate ⌘C keystroke via AppleScript (System Events)
    private func simulateCopy() {
        let script = NSAppleScript(source: """
            tell application "System Events"
                keystroke "c" using command down
            end tell
        """)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error = error {
            print("[Hotkey] AppleScript copy failed: \(error)")
        }
    }
}
