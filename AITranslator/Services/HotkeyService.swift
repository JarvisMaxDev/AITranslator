import Cocoa
import Carbon.HIToolbox

/// Manages global hotkey registration, text capture (AX API + clipboard fallback),
/// and delivers captured text via callback.
/// Extracted from AppDelegate to reduce God Object complexity.
@MainActor
final class HotkeyService {
    private var hotKeyRef: EventHotKeyRef?
    private var onTextCaptured: ((String) -> Void)?

    /// Last press timestamp for debounce
    private static var lastPressTime: CFAbsoluteTime = 0

    /// Initialize with a callback for captured text
    func start(onTextCaptured: @escaping (String) -> Void) {
        self.onTextCaptured = onTextCaptured

        // Listen for hotkey changes from Settings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeySettingsChanged),
            name: .hotkeyChanged,
            object: nil
        )

        registerHotkey()
    }

    /// Stop and unregister hotkey
    func stop() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    @objc private func hotkeySettingsChanged() {
        registerHotkey()
    }

    // MARK: - Hotkey Registration

    private func registerHotkey() {
        // Unregister old hotkey if any
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4149_5452), // "AITR"
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
                let now = CFAbsoluteTimeGetCurrent()
                if now - HotkeyService.lastPressTime < 0.5 {
                    return noErr
                }
                HotkeyService.lastPressTime = now

                let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()

                // Step 1: Try Accessibility API first (non-main thread to capture before focus changes)
                let pasteboard = NSPasteboard.general
                let oldContent = pasteboard.string(forType: .string) ?? ""

                if let text = HotkeyService.readSelectedText() {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\n+", with: "\n", options: .regularExpression)
                    DispatchQueue.main.async {
                        service.onTextCaptured?(trimmed)
                    }
                } else {
                    // AX failed — simulate Cmd+C
                    let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
                    AppLogger.shared.info("Hotkey", "AX failed for \(frontApp), falling back to Cmd+C")

                    // Reset modifier keys first
                    if let src = CGEventSource(stateID: .combinedSessionState) {
                        let flagsEvent = CGEvent(source: src)
                        flagsEvent?.flags = []
                        flagsEvent?.post(tap: .cghidEventTap)
                    }

                    // Wait for modifier reset, then send Cmd+C
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        if let src = CGEventSource(stateID: .combinedSessionState) {
                            src.localEventsSuppressionInterval = 0.05
                            let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true) // 'C'
                            let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false)
                            keyDown?.flags = .maskCommand
                            keyUp?.flags = .maskCommand
                            keyDown?.post(tap: .cghidEventTap)
                            keyUp?.post(tap: .cghidEventTap)
                        }

                        // Check clipboard after delay with retry
                        func checkAndRetry(attempt: Int, maxAttempts: Int) {
                            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                                let newContent = pasteboard.string(forType: .string) ?? ""
                                if !newContent.isEmpty && newContent != oldContent {
                                    let trimmed = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
                                    DispatchQueue.main.async {
                                        service.onTextCaptured?(trimmed)
                                    }
                                } else if attempt < maxAttempts {
                                    // Fallback: targeted AppleScript for frontmost process
                                    DispatchQueue.main.async {
                                        let script = "tell application \"System Events\" to keystroke \"c\" using command down"
                                        let task = Process()
                                        task.launchPath = "/usr/bin/osascript"
                                        task.arguments = ["-e", script]
                                        do { try task.run() } catch { }
                                        checkAndRetry(attempt: attempt + 1, maxAttempts: maxAttempts)
                                    }
                                } else {
                                    DispatchQueue.main.async {
                                        AppLogger.shared.log(.info, category: "Hotkey", message: "No selection after \(maxAttempts) attempts")
                                        service.onTextCaptured?("")
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

    // MARK: - Accessibility API

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
