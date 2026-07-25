import SwiftUI
import AppKit

/// The cog at the bottom of the sidebar: the handful of things this fork adds
/// on top of Ghostty, in the one place you'd look for them.
///
/// Kept deliberately small. Anything that belongs in Ghostty's own config file
/// stays there; this is only for settings we've added and the couple of
/// actions that are awkward to reach otherwise.
struct SidebarSettingsMenu: View {
    @ObservedObject var tabManager: SidebarTabManager
    let theme: SidebarTheme

    @State private var isHovered = false
    @State private var paneKeeper = false
    @State private var writeFailed = false

    private var appDelegate: AppDelegate? {
        NSApp.delegate as? AppDelegate
    }

    var body: some View {
        Menu {
            Button {
                tabManager.createNewTab(projectRoot: NSHomeDirectory())
            } label: {
                Label("New Terminal in Home", systemImage: "house")
                    .labelStyle(.titleAndIcon)
            }
            .help("Opens a tab in your home folder, ignoring the current tab's directory.")

            Divider()

            // A checkmark rather than a Toggle: menu items bridged into a
            // native menu render a Toggle as a plain row, with nothing to say
            // whether it's on.
            Button {
                togglePaneKeeper()
            } label: {
                Label(
                    "Keep Terminals Running After Quit",
                    systemImage: paneKeeper ? "checkmark.circle.fill" : "circle"
                )
                .labelStyle(.titleAndIcon)
            }
            // The caveats are the part people get bitten by, so they belong
            // here rather than in a doc nobody opens.
            .help(paneKeeper
                ? """
                On. Quitting leaves your shells running and reopening puts \
                them back with their output. Closing a tab still ends it, and \
                shutting down or logging out ends everything. Each terminal \
                costs one small background process.
                """
                : """
                Off. Quitting ends every shell. Turn this on and they keep \
                running instead, so reopening restores them exactly as you \
                left them — including across an app update. Takes effect for \
                terminals opened from now on.
                """)

            if writeFailed {
                Text("Couldn't write your config file — check permissions")
            }

            Divider()

            Button {
                appDelegate?.updateController.checkForUpdates()
            } label: {
                Label("Check for Updates…", systemImage: "arrow.down.circle")
                    .labelStyle(.titleAndIcon)
            }
            .help("Asks now instead of waiting for the automatic check.")
        } label: {
            ZStack {
                Color.clear
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(
                        isHovered ? theme.foreground : theme.foreground.opacity(0.6)
                    )
            }
            .frame(width: 22, height: 22)
        }
        // Not `.borderlessButton`: that style drops the artwork on every item
        // in the menu it presents.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Ghostty Pro Plus Ultra settings")
        .onHover { isHovered = $0 }
        .onAppear { refresh() }
    }

    private func refresh() {
        paneKeeper = appDelegate?.ghostty.config.paneKeeper ?? false
    }

    /// Flip the setting in the user's config file, then reload so it takes
    /// effect without a restart.
    ///
    /// Existing panes keep whatever they started as — a running shell can't be
    /// moved under a keeper after the fact — so this applies to panes opened
    /// from here on, and fully after the next restart.
    private func togglePaneKeeper() {
        let next = !paneKeeper
        guard ForkSettings.write(key: "pane-keeper", value: next ? "true" : "false") else {
            writeFailed = true
            return
        }

        writeFailed = false
        paneKeeper = next
        appDelegate?.ghostty.reloadConfig()
    }
}
