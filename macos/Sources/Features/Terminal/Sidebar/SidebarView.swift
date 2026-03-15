import SwiftUI
import UniformTypeIdentifiers

// MARK: - SidebarTheme

struct SidebarTheme: Equatable {
    let background: Color
    let foreground: Color
    let secondaryText: Color
    let activeTabBackground: Color
    let attentionColor: Color

    /// Create from Ghostty terminal colors.
    static func from(background: NSColor, foreground: NSColor) -> SidebarTheme {
        let bgLuminance = background.luminance
        let sidebarBg: Color
        if bgLuminance > 0.5 {
            // Light theme: darken sidebar slightly
            sidebarBg = Color(nsColor: background.darken(by: 0.05))
        } else {
            // Dark theme: lighten sidebar slightly
            sidebarBg = Color(nsColor: background.blended(withFraction: 0.08, of: NSColor.white) ?? background)
        }

        let fg = Color(nsColor: foreground)

        return SidebarTheme(
            background: sidebarBg,
            foreground: fg,
            secondaryText: fg.opacity(0.6),
            activeTabBackground: fg.opacity(0.12),
            attentionColor: .orange
        )
    }

    /// Sensible default when no terminal colors are available yet.
    static var `default`: SidebarTheme {
        SidebarTheme(
            background: Color(nsColor: .controlBackgroundColor),
            foreground: .primary,
            secondaryText: .secondary,
            activeTabBackground: Color.accentColor.opacity(0.12),
            attentionColor: .orange
        )
    }
}

// MARK: - SidebarField

enum SidebarField: String, Hashable {
    case title
    case directory
    case gitBranch = "git-branch"
    case status

    static let defaultFields: Set<SidebarField> = [.title, .directory, .gitBranch, .status]
}

// MARK: - SidebarView

/// A vertical sidebar that displays the list of tabs for the current window group.
struct SidebarView: View {
    @ObservedObject var tabManager: SidebarTabManager
    var theme: SidebarTheme
    var fields: Set<SidebarField> = SidebarField.defaultFields

    @AppStorage("SidebarShowCardBorder") private var showCardBorder: Bool = true
    @State private var draggingTabID: ObjectIdentifier?
    @State private var dropTargetTabID: ObjectIdentifier?
    @State private var hoveredTabID: ObjectIdentifier?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                    SidebarTabCard(tab: tab, theme: theme, fields: fields, showCardBorder: showCardBorder, isHovered: hoveredTabID == tab.id)
                        .contentShape(Rectangle())
                        .onHover { isHovering in
                            hoveredTabID = isHovering ? tab.id : nil
                        }
                        .opacity(draggingTabID == tab.id ? 0.4 : 1.0)
                        .overlay(alignment: .top) {
                            if dropTargetTabID == tab.id && draggingTabID != tab.id {
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(height: 2)
                                    .offset(y: -3)
                            }
                        }
                        .onTapGesture {
                            tabManager.selectTab(tab)
                        }
                        .overlay(MiddleClickOverlay {
                            tabManager.closeTab(tab)
                        })
                        .onDrag {
                            draggingTabID = tab.id
                            return NSItemProvider(object: "\(index)" as NSString)
                        }
                        .onDrop(of: [UTType.text], delegate: TabDropDelegate(
                            tabManager: tabManager,
                            currentTab: tab,
                            currentIndex: index,
                            draggingTabID: $draggingTabID,
                            dropTargetTabID: $dropTargetTabID
                        ))
                        .contextMenu {
                            Button("Rename Tab...") {
                                tabManager.promptRenameTab(tab)
                            }

                            Divider()

                            Menu("Tab Color") {
                                ForEach(TerminalTabColor.allCases, id: \.self) { color in
                                    Button {
                                        tabManager.setTabColor(color, for: tab)
                                    } label: {
                                        Label {
                                            Text(color.localizedName)
                                        } icon: {
                                            Image(nsImage: color.swatchImage(selected: color == tab.tabColor))
                                        }
                                    }
                                }
                            }

                            Toggle("Show Tab Border", isOn: $showCardBorder)

                            Divider()

                            Button("Close Tab") {
                                tabManager.closeTab(tab)
                            }

                            Button("Close Other Tabs") {
                                tabManager.closeOtherTabs(tab)
                            }
                            .disabled(tabManager.tabs.count <= 1)

                            Button("Close Tabs to the Right") {
                                tabManager.closeTabsToTheRight(of: tab)
                            }
                            .disabled({
                                guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else { return true }
                                return idx >= tabManager.tabs.count - 1
                            }())
                        }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            tabManager.createNewTab()
        }
        .onAppear {
            // Make tooltips appear near-instantly (default is ~1.5s)
            UserDefaults.standard.set(100, forKey: "NSInitialToolTipDelay")
        }
    }
}

// MARK: - TabDropDelegate

private struct TabDropDelegate: DropDelegate {
    let tabManager: SidebarTabManager
    let currentTab: SidebarTabManager.TabItem
    let currentIndex: Int
    @Binding var draggingTabID: ObjectIdentifier?
    @Binding var dropTargetTabID: ObjectIdentifier?

    func dropEntered(info: DropInfo) {
        dropTargetTabID = currentTab.id
    }

    func dropExited(info: DropInfo) {
        if dropTargetTabID == currentTab.id {
            dropTargetTabID = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggingTabID != nil && draggingTabID != currentTab.id
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggingTabID else { return false }
        guard let sourceIndex = tabManager.tabs.firstIndex(where: { $0.id == draggingTabID }) else { return false }

        tabManager.moveTab(from: sourceIndex, to: currentIndex)

        self.draggingTabID = nil
        self.dropTargetTabID = nil
        return true
    }
}

// MARK: - SidebarTabCard

private struct SidebarTabCard: View {
    let tab: SidebarTabManager.TabItem
    let theme: SidebarTheme
    let fields: Set<SidebarField>
    var showCardBorder: Bool = true
    var isHovered: Bool = false

    private static let cardRadius: CGFloat = 8

    /// The accent color for the left border strip.
    /// Full intensity for the selected tab, dimmed for inactive tabs.
    private var accentColor: Color {
        if let nsColor = tab.tabColor.displayColor {
            let base = Color(nsColor: nsColor)
            return tab.isSelected ? base : base.opacity(0.4)
        }
        return Color(nsColor: .separatorColor).opacity(tab.isSelected ? 0.3 : 0.15)
    }

    /// The border color for the thin card border — always neutral gray.
    private var cardBorderColor: Color {
        Color(nsColor: .separatorColor).opacity(0.3)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left color accent strip — uses UnevenRoundedRectangle so it
            // follows the card's left-side rounding while staying flat on the right.
            UnevenRoundedRectangle(
                topLeadingRadius: Self.cardRadius,
                bottomLeadingRadius: Self.cardRadius,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
            .fill(accentColor)
            .frame(width: 5)

            VStack(alignment: .leading, spacing: 4) {
                // Title (always shown — attention dot lives here)
                if fields.contains(.title) {
                    HStack(spacing: 6) {
                        Text(tab.displayTitle)
                            .font(.system(size: 12, weight: tab.isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundColor(tab.isSelected ? theme.foreground : theme.secondaryText)

                        Spacer()

                        if let activeEntry = tab.statusEntries.first(where: { $0.key == "claude-active" }) {
                            if activeEntry.value == "done" {
                                Circle()
                                    .fill(.green)
                                    .frame(width: 8, height: 8)
                            } else {
                                PulsingDot(color: .accentColor)
                            }
                        } else if tab.needsAttention {
                            Circle()
                                .fill(theme.attentionColor)
                                .frame(width: 8, height: 8)
                        }
                    }
                }

                // Directory name + git diff stats
                if fields.contains(.directory), let dir = tab.directoryName {
                    HStack(spacing: 4) {
                        if let favicon = tab.faviconImage {
                            Image(nsImage: favicon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 11, height: 11)
                        } else {
                            Image(systemName: "folder")
                                .font(.system(size: 9))
                                .foregroundColor(theme.secondaryText)
                        }
                        Text(dir)
                            .font(.system(size: 10))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)

                        if let stats = tab.gitDiffStats {
                            Spacer()
                            Text(stats)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(theme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                }

                // Claude session summary
                if let claudeEntry = tab.statusEntries.first(where: { $0.key == "claude" }) {
                    HStack(spacing: 4) {
                        Image(systemName: claudeEntry.icon ?? "bubble.left.fill")
                            .font(.system(size: 9))
                            .foregroundColor(theme.secondaryText)
                        Text(claudeEntry.value)
                            .font(.system(size: 10))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .help(claudeEntry.value)
                }

                // Status entries (excluding "claude" which is shown in the branch slot)
                if fields.contains(.status) {
                    let filteredEntries = tab.statusEntries.filter { $0.key != "claude" && $0.key != "claude-active" }
                    ForEach(filteredEntries, id: \.key) { entry in
                        HStack(spacing: 4) {
                            if let icon = entry.icon {
                                Image(systemName: icon)
                                    .font(.system(size: 9))
                                    .foregroundColor(theme.secondaryText)
                            }
                            Text(entry.value)
                                .font(.system(size: 10))
                                .foregroundColor(theme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.leading, 8)
            .padding(.trailing, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cardRadius))
        .background(
            RoundedRectangle(cornerRadius: Self.cardRadius)
                .fill(tab.isSelected ? theme.activeTabBackground : (isHovered ? theme.foreground.opacity(0.06) : Color.clear))
        )
        .overlay(
            Group {
                if showCardBorder {
                    RoundedRectangle(cornerRadius: Self.cardRadius)
                        .strokeBorder(cardBorderColor, lineWidth: 1)
                }
            }
        )
    }
}

// MARK: - MiddleClickOverlay

/// Transparent NSView overlay that captures middle-click (button 2) events.
private struct MiddleClickOverlay: NSViewRepresentable {
    var action: () -> Void

    func makeNSView(context: Context) -> MiddleClickView {
        MiddleClickView(action: action)
    }

    func updateNSView(_ nsView: MiddleClickView, context: Context) {
        nsView.action = action
    }

    class MiddleClickView: NSView {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Only intercept middle-click events; pass everything else through
            // so SwiftUI gestures (tap, hover, drag) work normally.
            if let event = NSApp.currentEvent,
               event.type == .otherMouseDown || event.type == .otherMouseUp {
                return super.hitTest(point)
            }
            return nil
        }

        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 {
                action()
            } else {
                super.otherMouseUp(with: event)
            }
        }
    }
}

// MARK: - PulsingDot

/// Animated pulsing dot that indicates Claude Code is actively working.
/// Runs as a SwiftUI animation, so it stays animated even when the tab is not focused.
private struct PulsingDot: View {
    let color: Color
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(isPulsing ? 0.3 : 1.0)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}
