import Cocoa

/// Manages the menu bar status item and its dropdown menu.
/// Extracted from AppDelegate to reduce God Object complexity.
@MainActor
final class StatusBarController {
    private var statusItem: NSStatusItem?

    struct Actions {
        let showTranslator: () -> Void
        let openSettings: () -> Void
        let openConsole: () -> Void
        let quit: () -> Void
    }

    private var actions: Actions?

    func setup(actions: Actions) {
        self.actions = actions

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "AI Translator")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: NSLocalizedString("menu.show_translator", comment: "Show Translator"),
            action: #selector(showTranslator),
            keyEquivalent: "t"
        ))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: NSLocalizedString("menu.console", comment: "Console"),
            action: #selector(openConsole),
            keyEquivalent: "l"
        ))
        menu.addItem(NSMenuItem(
            title: NSLocalizedString("menu.settings", comment: "Settings..."),
            action: #selector(openSettings),
            keyEquivalent: ","
        ))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: NSLocalizedString("menu.quit", comment: "Quit"),
            action: #selector(quitApp),
            keyEquivalent: "q"
        ))

        // Set self as target for all menu items
        for item in menu.items where item.action != nil {
            item.target = self
        }

        statusItem?.menu = menu
    }

    @objc private func showTranslator() {
        actions?.showTranslator()
    }

    @objc private func openSettings() {
        actions?.openSettings()
    }

    @objc private func openConsole() {
        actions?.openConsole()
    }

    @objc private func quitApp() {
        actions?.quit()
    }
}
