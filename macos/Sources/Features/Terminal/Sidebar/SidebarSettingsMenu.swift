import SwiftUI
import AppKit

/// The cog at the bottom of the sidebar: the handful of things this fork adds
/// on top of Ghostty, in the one place you'd look for them.
///
/// Built as an AppKit menu rather than SwiftUI's `Menu`. SwiftUI's version is
/// bridged into a native menu on macOS but only exposes a fraction of what a
/// menu row can do: no tooltips, no subtitle lines, no say in whether an icon
/// survives the system's image policy. This menu wants all three, so it drives
/// `NSMenu` directly.
struct SidebarSettingsMenu: View {
    @ObservedObject var tabManager: SidebarTabManager
    let theme: SidebarTheme

    @State private var isHovered = false

    var body: some View {
        SettingsMenuButton(tabManager: tabManager)
            .frame(width: 22, height: 22)
            .opacity(isHovered ? 1 : 0.75)
            .onHover { isHovered = $0 }
            .help("Ghostty Pro Plus Ultra settings")
    }
}

/// The cog button and its menu.
private struct SettingsMenuButton: NSViewRepresentable {
    let tabManager: SidebarTabManager

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: "Settings"
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        button.contentTintColor = .secondaryLabelColor
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.tabManager = tabManager
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(tabManager: tabManager)
    }

    @MainActor
    final class Coordinator: NSObject {
        var tabManager: SidebarTabManager

        init(tabManager: SidebarTabManager) {
            self.tabManager = tabManager
        }

        private var appDelegate: AppDelegate? {
            NSApp.delegate as? AppDelegate
        }

        private var persistentTerminals: Bool {
            appDelegate?.ghostty.config.paneKeeper ?? false
        }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            // No checkmark gutter. With only one item that carries state,
            // the column costs every row an indent to say nothing; the
            // toggle shows a checkmark in its own icon slot instead.
            menu.showsStateColumn = false

            add(
                to: menu,
                title: "New Terminal in Home",
                symbol: "house",
                tooltip: "Opens a tab in your home folder, ignoring the current tab's directory.",
                action: #selector(newHomeTerminal)
            )

            menu.addItem(.separator())

            let on = persistentTerminals
            let toggle = add(
                to: menu,
                title: "Persistent Terminals",
                // Same circle in both states, filled with a checkmark when
                // on. Two glyphs that share a shape read as one switch; two
                // unrelated glyphs just read as two different things.
                symbol: on ? "checkmark.circle.fill" : "circle",
                tooltip: on
                    ? """
                    On. Quitting leaves your terminals running and reopening puts them \
                    back with their output, including across an app update.

                    Closing a tab still ends it. Shutting down or logging out ends \
                    everything. Terminals already open are unaffected. Costs one small \
                    background process per terminal.
                    """
                    : """
                    Off. Quitting ends every terminal.

                    Turn this on and they keep running instead, so reopening Ghostty \
                    restores them exactly as you left them — same processes, same \
                    output on screen — including across an app update.

                    Applies to terminals opened from now on.
                    """,
                action: #selector(togglePersistentTerminals)
            )
            // Subtitles arrived in 14.4 and the deployment target is older;
            // without one the tooltip still carries the detail.
            if #available(macOS 14.4, *) {
                toggle.subtitle = "Survive quitting and reopening"
            }

            menu.addItem(.separator())

            add(
                to: menu,
                title: "Check for Updates…",
                symbol: "arrow.down.circle",
                tooltip: "Asks now instead of waiting for the automatic check.",
                action: #selector(checkForUpdates)
            )

            // Below the cog, so the menu doesn't cover the sidebar.
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.height + 4),
                in: sender
            )
        }

        @discardableResult
        private func add(
            to menu: NSMenu,
            title: String,
            symbol: String,
            tooltip: String,
            action: Selector
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.toolTip = tooltip
            item.image = NSImage(
                systemSymbolName: symbol,
                accessibilityDescription: nil
            )
            // macOS 27 hides symbol images in menus unless the item asks for
            // them. Ours identify the three actions at a glance, so they stay.
            if #available(macOS 27.0, *) {
                item.preferredImageVisibility = .visible
            }
            menu.addItem(item)
            return item
        }

        // MARK: - Actions

        @objc private func newHomeTerminal() {
            tabManager.createNewTab(projectRoot: NSHomeDirectory())
        }

        @objc private func checkForUpdates() {
            appDelegate?.updateController.checkForUpdates()
        }

        /// Flip the setting in the user's config file, then reload so it takes
        /// effect without a restart.
        ///
        /// Terminals already open keep whatever they started as — a running
        /// shell can't be moved under a keeper after the fact — so this
        /// applies to ones opened from here on.
        @objc private func togglePersistentTerminals() {
            let next = !persistentTerminals
            guard ForkSettings.write(
                key: "pane-keeper",
                value: next ? "true" : "false"
            ) else {
                let alert = NSAlert()
                alert.messageText = "Couldn't save that setting"
                alert.informativeText = """
                Your Ghostty config file couldn't be written:

                \(ForkSettings.configPath)

                Check its permissions, or set `pane-keeper` there by hand.
                """
                alert.alertStyle = .warning
                alert.runModal()
                return
            }

            appDelegate?.ghostty.reloadConfig()
        }
    }
}
