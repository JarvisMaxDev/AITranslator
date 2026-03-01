import Cocoa
import SwiftUI
import Carbon.HIToolbox

/// AppDelegate handles global hotkey registration and menu bar status item.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popupWindow: NSWindow?
    private var popupHostingController: NSHostingController<AnyView>?
    private var hotKeyRef: EventHotKeyRef?
    /// Shared SettingsViewModel — injected from AITranslatorApp after launch
    var settingsViewModel: SettingsViewModel?

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
        // Register ⌘⇧C as global hotkey using Carbon API
        // This works WITHOUT Accessibility permissions!
        let hotKeyID = EventHotKeyID(signature: OSType(0x5452_4E53), // "TRNS"
                                      id: 1)

        // Install handler for hotkey events
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
                    delegate.showPopupTranslator()
                }
                return noErr
            },
            1, &eventType, handlerPtr, nil
        )

        // keyCode 8 = 'c', cmdKey | shiftKey modifiers
        let modifiers = UInt32(cmdKey | shiftKey)
        let keyCode = UInt32(kVK_ANSI_C)

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                          GetApplicationEventTarget(), 0, &ref)

        if status == noErr {
            hotKeyRef = ref
            print("[Hotkey] ⌘⇧C registered successfully (no Accessibility needed)")
        } else {
            print("[Hotkey] Failed to register ⌘⇧C hotkey: \(status)")
        }
    }

    // MARK: - Popup Translator

    func showPopupTranslator() {
        // Grab clipboard text — user likely copied before pressing hotkey
        let clipboardText = NSPasteboard.general.string(forType: .string) ?? ""

        if let existing = popupWindow, existing.isVisible {
            existing.close()
        }

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

        if !clipboardText.isEmpty {
            Task {
                await translatorVM.translate()
            }
        }
    }
}
