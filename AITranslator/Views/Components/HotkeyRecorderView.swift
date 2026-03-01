import SwiftUI
import Carbon.HIToolbox

/// A view that records a keyboard shortcut when clicked.
/// User clicks, presses a key combo, and the new shortcut is saved.
struct HotkeyRecorderView: View {
    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32
    @State private var isRecording = false

    var body: some View {
        Button(action: { isRecording.toggle() }) {
            HStack(spacing: 6) {
                if isRecording {
                    Text(NSLocalizedString("settings.hotkey_press", comment: "Press shortcut..."))
                        .foregroundStyle(.orange)
                } else {
                    Text(Self.hotkeyDisplayString(keyCode: keyCode, modifiers: modifiers))
                        .fontWeight(.medium)
                }
                Image(systemName: isRecording ? "keyboard.badge.ellipsis" : "keyboard")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isRecording ? Color.orange.opacity(0.1) : Color.secondary.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isRecording ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .background(isRecording ? KeyEventCatcher(onKeyEvent: handleKeyEvent) : nil)
    }

    private func handleKeyEvent(event: NSEvent) {
        guard isRecording else { return }

        // Require at least one modifier (Cmd, Ctrl, Option, Shift)
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard !mods.isEmpty else { return }

        let carbonMods = Self.cocoaToCarbonModifiers(mods)
        keyCode = UInt32(event.keyCode)
        modifiers = carbonMods
        isRecording = false

        // Save to UserDefaults
        UserDefaults.standard.set(Int(keyCode), forKey: Constants.UserDefaultsKeys.hotkeyKeyCode)
        UserDefaults.standard.set(Int(modifiers), forKey: Constants.UserDefaultsKeys.hotkeyModifiers)

        // Notify AppDelegate to re-register
        NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
    }

    // MARK: - Display helpers

    /// Convert keyCode + Carbon modifiers to a readable string like "⌘⇧C"
    static func hotkeyDisplayString(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts: [String] = []

        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }

        let keyName = Self.keyCodeToString(keyCode)
        parts.append(keyName)

        return parts.joined()
    }

    /// Map a virtual key code to a display string
    static func keyCodeToString(_ keyCode: UInt32) -> String {
        let mapping: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↵",
            UInt32(kVK_Tab): "⇥", UInt32(kVK_Escape): "⎋",
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
            UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
            UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
            UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        ]
        return mapping[keyCode] ?? "?"
    }

    /// Convert Cocoa NSEvent.ModifierFlags to Carbon modifier mask
    static func cocoaToCarbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }
}

// MARK: - Notification

extension Notification.Name {
    static let hotkeyChanged = Notification.Name("hotkeyChanged")
}

// MARK: - Key Event Catcher (NSViewRepresentable)

/// An invisible NSView that captures key events for hotkey recording
struct KeyEventCatcher: NSViewRepresentable {
    let onKeyEvent: (NSEvent) -> Void

    func makeNSView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.onKeyEvent = onKeyEvent
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: KeyCatcherView, context: Context) {
        nsView.onKeyEvent = onKeyEvent
    }
}

class KeyCatcherView: NSView {
    var onKeyEvent: ((NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        onKeyEvent?(event)
    }
}
