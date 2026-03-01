import Cocoa
import SwiftUI
import Carbon.HIToolbox

/// Callback for CGEvent tap — must be a free function (not a method)
/// Detects double ⌘C within 0.4s
private var lastCmdCTime: Date?
private var appDelegateRef: AppDelegate?

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Pass through non-keyDown events
    guard type == .keyDown else {
        // If the tap is disabled by the system, re-enable it
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let refcon = refcon {
                let pointer = refcon.assumingMemoryBound(to: CFMachPort?.self)
                if let tap = pointer.pointee {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
        }
        return Unmanaged.passRetained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags

    // Check for ⌘C (keyCode 8 = 'c', Command flag set)
    guard keyCode == 8, flags.contains(.maskCommand) else {
        lastCmdCTime = nil
        return Unmanaged.passRetained(event)
    }

    let now = Date()
    if let lastTime = lastCmdCTime, now.timeIntervalSince(lastTime) < 0.4 {
        // Double ⌘C detected!
        lastCmdCTime = nil
        DispatchQueue.main.async {
            appDelegateRef?.showPopupTranslator()
        }
    } else {
        lastCmdCTime = now
    }

    // Always pass the event through so ⌘C still copies
    return Unmanaged.passRetained(event)
}

/// AppDelegate handles global hotkey registration and menu bar status item.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popupWindow: NSWindow?
    private var popupHostingController: NSHostingController<AnyView>?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Shared SettingsViewModel — injected from AITranslatorApp after launch
    var settingsViewModel: SettingsViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appDelegateRef = self
        setupStatusItem()
        requestAccessibilityIfNeeded()
        setupGlobalHotkey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
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

    // MARK: - Global Hotkey (Double ⌘C via CGEvent Tap)

    private func setupGlobalHotkey() {
        // Allocate storage for the tap reference so the callback can re-enable it
        let tapPointer = UnsafeMutablePointer<CFMachPort?>.allocate(capacity: 1)
        tapPointer.initialize(to: nil)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: eventTapCallback,
            userInfo: tapPointer
        ) else {
            print("[Hotkey] Failed to create CGEvent tap. Check Accessibility permissions.")
            tapPointer.deallocate()
            return
        }

        tapPointer.pointee = tap
        eventTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        print("[Hotkey] CGEvent tap installed — double ⌘C active")
    }

    // MARK: - Popup Translator

    func showPopupTranslator() {
        // Small delay to let ⌘C finish copying to clipboard
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.presentPopup()
        }
    }

    private func presentPopup() {
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
