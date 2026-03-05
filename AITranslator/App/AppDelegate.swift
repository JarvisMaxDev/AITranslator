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
        AppLogger.shared.info("Accessibility", "Trusted: \(trusted)")

        if !trusted {
            // Re-check after a delay — user may grant access via system dialog
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
        menu.addItem(NSMenuItem(title: NSLocalizedString("menu.console", comment: "Console"), action: #selector(openConsole), keyEquivalent: "l"))
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
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    private var consoleWindow: NSWindow?

    @objc private func openConsole() {
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

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Global Hotkey (configurable, default ⌘⇧C)

    private func setupGlobalHotkey() {
        // Listen for hotkey changes from Settings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeySettingsChanged),
            name: .hotkeyChanged,
            object: nil
        )

        registerHotkey()
    }

    @objc private func hotkeySettingsChanged() {
        registerHotkey()
    }

    private func registerHotkey() {
        // Unregister old hotkey if any
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x5452_4E53), // "TRNS"
                                      id: 1)

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        // Use Unmanaged to safely pass self to the Carbon callback
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }

                // Debounce: ignore repeated presses within 500ms
                struct Debounce { static var lastFire: Date = .distantPast }
                let now = Date()
                guard now.timeIntervalSince(Debounce.lastFire) > 0.5 else {
                    AppLogger.shared.log(.info, category: "Hotkey", message: "Debounced (too fast)")
                    return noErr
                }
                Debounce.lastFire = now

                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                let selectedText = AppDelegate.readSelectedText()

                if let text = selectedText, !text.isEmpty {
                    // AX worked (most apps) — use selected text directly
                    let hasNewlines = text.contains("\n")
                    let newlineCount = text.filter { $0 == "\n" }.count
                    AppLogger.shared.log(.info, category: "Hotkey", message: "AX captured '\(text.prefix(30))...' (len=\(text.count), newlines=\(newlineCount), hasNL=\(hasNewlines))")
                    DispatchQueue.main.async {
                        delegate.handleHotkey(text: text)
                    }
                } else {
                    // AX failed — simulate Cmd+C
                    let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
                    AppLogger.shared.log(.info, category: "Hotkey", message: "AX returned nil, frontmost=\(frontApp), simulating Cmd+C")

                    // Save current clipboard
                    let pasteboard = NSPasteboard.general
                    let oldChangeCount = pasteboard.changeCount
                    let oldContent = pasteboard.string(forType: .string)

                    // Step 1: Clear modifier flags so target app sees clean state
                    if let src = CGEventSource(stateID: .combinedSessionState) {
                        if let flagsEvent = CGEvent(source: src) {
                            flagsEvent.type = .flagsChanged
                            flagsEvent.flags = []
                            flagsEvent.post(tap: .cghidEventTap)
                        }
                    }

                    // Step 2: After delay, send Cmd+C via CGEvent with combinedSessionState
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        if let src = CGEventSource(stateID: .combinedSessionState) {
                            let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true)
                            let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false)
                            keyDown?.flags = .maskCommand
                            keyUp?.flags = .maskCommand
                            keyDown?.post(tap: .cghidEventTap)
                            keyUp?.post(tap: .cghidEventTap)
                        }

                        // Step 3: Check clipboard after delay with retry
                        func checkAndRetry(attempt: Int, maxAttempts: Int) {
                            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                                let newContent = pasteboard.string(forType: .string) ?? ""
                                let didChange = pasteboard.changeCount != oldChangeCount

                                if didChange && !newContent.isEmpty {
                                    if let old = oldContent {
                                        pasteboard.clearContents()
                                        pasteboard.setString(old, forType: .string)
                                    }
                                    DispatchQueue.main.async {
                                        AppLogger.shared.log(.info, category: "Hotkey", message: "Cmd+C captured on attempt \(attempt): '\(newContent.prefix(30))...'")
                                        delegate.handleHotkey(text: newContent)
                                    }
                                } else if attempt < maxAttempts {
                                    // Fallback: targeted AppleScript for frontmost process
                                    DispatchQueue.main.async {
                                        AppLogger.shared.log(.info, category: "Hotkey", message: "Cmd+C attempt \(attempt)/\(maxAttempts): no change, trying AppleScript for '\(frontApp)'")
                                        let task = Process()
                                        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                                        task.arguments = ["-e", """
                                            tell application "System Events"
                                                tell process "\(frontApp)"
                                                    keystroke "c" using command down
                                                end tell
                                            end tell
                                            """]
                                        do { try task.run() } catch { }
                                        checkAndRetry(attempt: attempt + 1, maxAttempts: maxAttempts)
                                    }
                                } else {
                                    DispatchQueue.main.async {
                                        AppLogger.shared.log(.info, category: "Hotkey", message: "No selection after \(maxAttempts) attempts")
                                        delegate.handleHotkey(text: "")
                                    }
                                }
                            }
                        }

                        checkAndRetry(attempt: 1, maxAttempts: 3)
                    }
                }
                return noErr
            },
            1, &eventType, selfPtr, nil
        )

        // Read from UserDefaults or use default ⌘⇧C
        let keyCode: UInt32
        let modifiers: UInt32

        let savedKeyCode = UserDefaults.standard.integer(forKey: Constants.UserDefaultsKeys.hotkeyKeyCode)
        let savedModifiers = UserDefaults.standard.integer(forKey: Constants.UserDefaultsKeys.hotkeyModifiers)

        if savedKeyCode > 0 && savedModifiers > 0 {
            keyCode = UInt32(savedKeyCode)
            modifiers = UInt32(savedModifiers)
        } else {
            keyCode = UInt32(kVK_ANSI_C)
            modifiers = UInt32(cmdKey | shiftKey)
        }

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                          GetApplicationEventTarget(), 0, &ref)

        let displayName = HotkeyRecorderView.hotkeyDisplayString(keyCode: keyCode, modifiers: modifiers)
        if status == noErr {
            hotKeyRef = ref
            print("[Hotkey] \(displayName) registered successfully")
        } else {
            print("[Hotkey] Failed to register \(displayName): \(status)")
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
