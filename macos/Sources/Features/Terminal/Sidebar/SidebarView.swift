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

/// A vertical sidebar that displays tabs grouped by project, styled after T3 Code.
struct SidebarView: View {
    @ObservedObject var tabManager: SidebarTabManager
    @ObservedObject var updateViewModel: UpdateViewModel
    var theme: SidebarTheme
    var fields: Set<SidebarField> = SidebarField.defaultFields

    @State private var draggingTabID: ObjectIdentifier?
    @State private var dropTargetTabID: ObjectIdentifier?
    @State private var hoveredTabID: ObjectIdentifier?
    @State private var hoveredGroupID: String?
    @State private var tabCardFrames: [ObjectIdentifier: CGRect] = [:]
    @State private var draggingGroupID: String?
    @State private var dropTargetGroupID: String?
    private static let scrollCoordinateSpace = "SidebarScrollCoordinateSpace"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Top padding to clear the title bar / traffic lights area
                Spacer().frame(height: 10)

                // Sort control header
                SidebarSortHeader(tabManager: tabManager, theme: theme)
                    .padding(.bottom, 6)

                ForEach(tabManager.projectGroups) { group in
                    ProjectSection(
                        group: group,
                        tabManager: tabManager,
                        theme: theme,
                        fields: fields,
                        draggingTabID: $draggingTabID,
                        dropTargetTabID: $dropTargetTabID,
                        hoveredTabID: $hoveredTabID,
                        hoveredGroupID: $hoveredGroupID,
                        tabCardFrames: $tabCardFrames,
                        isCollapsed: tabManager.collapsedProjects.contains(group.id)
                    )
                    .opacity(draggingGroupID == group.id ? 0.4 : 1.0)
                    .overlay(alignment: .top) {
                        if dropTargetGroupID == group.id && draggingGroupID != group.id {
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(height: 2)
                                .offset(y: -1)
                        }
                    }
                    .onDrag {
                        draggingGroupID = group.id
                        return NSItemProvider(object: group.id as NSString)
                    }
                    .onDrop(of: [UTType.text], delegate: ProjectGroupDropDelegate(
                        tabManager: tabManager,
                        currentGroup: group,
                        draggingGroupID: $draggingGroupID,
                        dropTargetGroupID: $dropTargetGroupID
                    ))
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
        }
        .coordinateSpace(name: Self.scrollCoordinateSpace)
        .onPreferenceChange(SidebarCardFramePreferenceKey.self) { tabCardFrames = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.clear)
        .safeAreaInset(edge: .bottom) {
            if !updateViewModel.state.isIdle {
                HStack {
                    Spacer()
                    UpdatePill(model: updateViewModel)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
        }
        .overlay(DoubleClickOverlay(
            tabCardFrames: tabCardFrames,
            onBlankSpaceDoubleClick: { tabManager.createNewTab(projectRoot: NSHomeDirectory()) },
            onTabDoubleClick: { tabID in
                if let tab = tabManager.tabs.first(where: { $0.id == tabID }) {
                    tabManager.promptRenameTab(tab)
                }
            }
        ))
    }
}

// MARK: - ProjectSection

/// A collapsible section for a project group with T3 Code-style vertical line indicator.
private struct ProjectSection: View {
    let group: SidebarTabManager.ProjectGroup
    @ObservedObject var tabManager: SidebarTabManager
    let theme: SidebarTheme
    let fields: Set<SidebarField>
    @Binding var draggingTabID: ObjectIdentifier?
    @Binding var dropTargetTabID: ObjectIdentifier?
    @Binding var hoveredTabID: ObjectIdentifier?
    @Binding var hoveredGroupID: String?
    @Binding var tabCardFrames: [ObjectIdentifier: CGRect]
    let isCollapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Project header
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    tabManager.toggleProjectCollapsed(group.id)
                }
            } label: {
                ProjectHeader(
                    group: group,
                    theme: theme,
                    isCollapsed: isCollapsed,
                    isHovered: hoveredGroupID == group.id,
                    onNewTab: { tool in
                        tabManager.createNewTab(tool: tool, projectRoot: group.projectRoot)
                    },
                    recentSessions: tabManager.cachedRecentSessions(forProjectRoot: group.projectRoot),
                    onResumeSession: { session in
                        tabManager.resumeSession(session, projectRoot: group.projectRoot)
                    }
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovering in
                hoveredGroupID = isHovering ? group.id : nil
            }

            // Thread list with vertical line indicator
            if !isCollapsed {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(group.tabs) { tab in
                        threadRow(for: tab)
                    }
                }
                .padding(.leading, 6)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(theme.foreground.opacity(0.06))
                        .frame(width: 1)
                }
                .padding(.leading, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.bottom, 2)
        .animation(.easeOut(duration: 0.18), value: isCollapsed)
    }

    @ViewBuilder
    private func threadRow(for tab: SidebarTabManager.TabItem) -> some View {
        let isSelected = tab.id == tabManager.selectedTabID
        let isHovered = hoveredTabID == tab.id
        let tabIndex = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) ?? 0

        let sessionTitleEntry = tab.statusEntries.first(where: { $0.key == "session-title" })
        let sessionStatusEntry = tab.statusEntries.first(where: { $0.key == "claude" || $0.key == "codex" })
        let activeEntry = tab.statusEntries.first(where: { $0.key == "claude-active" || $0.key == "codex-active" })
        let titleColor = isSelected || isHovered ? theme.foreground : theme.secondaryText
        let subtitleColor = isSelected || isHovered ? theme.foreground.opacity(0.7) : theme.secondaryText
        // Tab color tint — subtle background wash instead of a left bar
        let tabTint: Color? = tab.tabColor.displayColor.map { Color(nsColor: $0) }
        let rowBackground: Color = {
            if let tint = tabTint {
                if isSelected { return tint.opacity(0.12) }
                if isHovered { return tint.opacity(0.08) }
                return tint.opacity(0.05)
            }
            if isSelected { return theme.foreground.opacity(0.06) }
            if isHovered { return theme.foreground.opacity(0.04) }
            return .clear
        }()

        HStack(spacing: 0) {
            // Status dot — leading position
            if let activeEntry {
                if activeEntry.value == "done" {
                    Circle().fill(.green).frame(width: 6, height: 6).padding(.trailing, 6)
                } else if activeEntry.value == "needs-input" {
                    PulsingDot(color: .orange, size: 6).padding(.trailing, 6)
                } else {
                    PulsingDot(color: .accentColor, size: 6).padding(.trailing, 6)
                }
            } else if tab.needsAttention && !isSelected {
                Circle().fill(theme.attentionColor).frame(width: 6, height: 6).padding(.trailing, 6)
            }

            // Title
            let primaryTitle = sessionTitleEntry?.value ?? tab.displayTitle

            Text(primaryTitle)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(titleColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(primaryTitle)

            // Relative time — "3m", "1h" (time since last real activity)
            if let activity = tab.lastActivity {
                Text(relativeTime(activity))
                    .font(.system(size: 9))
                    .foregroundColor(theme.secondaryText.opacity(0.5))
                    .fixedSize()
            }
        }
        .frame(height: 28)
        .padding(.horizontal, 8)
        .offset(x: -1)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowBackground)
        )
        .onHover { hovering in
            hoveredTabID = hovering ? tab.id : nil
        }
        .onTapGesture {
            tabManager.selectTab(tab)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SidebarCardFramePreferenceKey.self,
                    value: [tab.id: proxy.frame(in: .named("SidebarScrollCoordinateSpace"))]
                )
            }
        }
        .overlay(MiddleClickOverlay {
            tabManager.closeTab(tab)
        })
        .onDrag {
            draggingTabID = tab.id
            return NSItemProvider(object: "\(tabIndex)" as NSString)
        }
        .onDrop(of: [UTType.text], delegate: TabDropDelegate(
            tabManager: tabManager,
            currentTab: tab,
            currentIndex: tabIndex,
            draggingTabID: $draggingTabID,
            dropTargetTabID: $dropTargetTabID
        ))
        .opacity(draggingTabID == tab.id ? 0.4 : 1.0)
        .overlay(alignment: .top) {
            if dropTargetTabID == tab.id && draggingTabID != tab.id {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .offset(y: -1)
            }
        }
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

            if let pwd = tab.pwd {
                Button("Open in Finder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: pwd))
                }
            }

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

// MARK: - ProjectHeader

/// The header row for a project group — matches T3 Code's compact header style.
private struct ProjectHeader: View {
    let group: SidebarTabManager.ProjectGroup
    let theme: SidebarTheme
    let isCollapsed: Bool
    let isHovered: Bool
    var onNewTab: ((SidebarTabManager.SidebarTool) -> Void)? = nil
    var recentSessions: [SidebarTabManager.RecentSession] = []
    var onResumeSession: ((SidebarTabManager.RecentSession) -> Void)? = nil
    @State private var isNewTabHovered = false

    var body: some View {
        HStack(spacing: 6) {
            // Collapse chevron — 14px, rotates 90° on expand
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.secondaryText.opacity(0.7))
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .animation(.easeInOut(duration: 0.15), value: isCollapsed)
                .frame(width: 14, height: 14)

            // Favicon or folder icon
            if let favicon = group.faviconImage {
                Image(nsImage: favicon)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .frame(width: 16, height: 16)
            } else if !group.isOtherGroup {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            }

            // Project name
            Text(group.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.foreground.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            // Git diff stats
            if let stats = group.gitDiffStats {
                Text(stats)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
            }

            if let onNewTab {
                Menu {
                    // New session options
                    ForEach(SidebarTabManager.SidebarTool.allCases, id: \.self) { tool in
                        Button {
                            onNewTab(tool)
                        } label: {
                            HStack(spacing: 6) {
                                SidebarToolMenuIcon(tool: tool)
                                Text(tool.rawValue)
                            }
                        }
                    }

                    // Recent sessions to resume
                    if !recentSessions.isEmpty, let onResumeSession {
                        Divider()
                        Text("Resume Session")
                            .font(.caption)
                        ForEach(recentSessions) { session in
                            Button {
                                onResumeSession(session)
                            } label: {
                                HStack(spacing: 6) {
                                    SidebarToolMenuIcon(tool: session.tool)
                                    Text(session.title)
                                        .lineLimit(1)
                                        .help(session.fullTitle)
                                }
                            }
                        }
                    }
                } label: {
                    ZStack {
                        Color.clear
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(isNewTabHovered ? theme.foreground : theme.foreground.opacity(0.7))
                    }
                    .frame(width: 20, height: 20)
                }
                .id(recentSessions.count)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
                .onHover { hovering in
                    isNewTabHovered = hovering
                }
            }
        }
        .contentShape(Rectangle())
        .frame(height: 28)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? theme.foreground.opacity(0.04) : Color.clear)
        )
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

private struct SidebarToolMenuIcon: View {
    let tool: SidebarTabManager.SidebarTool

    var body: some View {
        Group {
            if tool.isCustomIcon {
                Image(tool.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: tool.icon)
                    .font(.system(size: 14, weight: .medium))
            }
        }
    }
}

// MARK: - ProjectGroupDropDelegate

private struct ProjectGroupDropDelegate: DropDelegate {
    let tabManager: SidebarTabManager
    let currentGroup: SidebarTabManager.ProjectGroup
    @Binding var draggingGroupID: String?
    @Binding var dropTargetGroupID: String?

    func dropEntered(info: DropInfo) {
        dropTargetGroupID = currentGroup.id
    }

    func dropExited(info: DropInfo) {
        if dropTargetGroupID == currentGroup.id {
            dropTargetGroupID = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggingGroupID != nil && draggingGroupID != currentGroup.id
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggingGroupID else { return false }

        // Switch to manual sort mode and perform the move
        tabManager.setProjectSortMode(.manual)
        tabManager.moveProjectGroup(fromId: draggingGroupID, toId: currentGroup.id)

        self.draggingGroupID = nil
        self.dropTargetGroupID = nil
        return true
    }
}

// MARK: - SidebarSortHeader

/// A compact header row with sort controls.
private struct SidebarSortHeader: View {
    @ObservedObject var tabManager: SidebarTabManager
    let theme: SidebarTheme

    var body: some View {
        HStack(spacing: 4) {
            Text("PROJECTS")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(theme.secondaryText.opacity(0.6))
                .tracking(0.5)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
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
        defer {
            self.draggingTabID = nil
            self.dropTargetTabID = nil
        }
        guard let draggingTabID else { return false }
        guard let sourceIndex = tabManager.tabs.firstIndex(where: { $0.id == draggingTabID }) else { return false }

        tabManager.moveTab(from: sourceIndex, to: currentIndex)
        return true
    }
}

// MARK: - Relative Time Helper

/// Format a date as a relative time string: "now", "3m", "1h", "2d"
private func relativeTime(_ date: Date) -> String {
    let seconds = Int(Date().timeIntervalSince(date))
    if seconds < 60 { return "now" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h" }
    let days = hours / 24
    return "\(days)d"
}

// MARK: - Conditional View Modifier

private extension View {
    /// Apply a modifier only when a condition is true.
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
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

private struct SidebarCardFramePreferenceKey: PreferenceKey {
    static var defaultValue: [ObjectIdentifier: CGRect] = [:]

    static func reduce(value: inout [ObjectIdentifier: CGRect], nextValue: () -> [ObjectIdentifier: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// MARK: - DoubleClickOverlay

/// Transparent NSView overlay that monitors double-click events via an event
/// monitor, bypassing SwiftUI's gesture system entirely.
private struct DoubleClickOverlay: NSViewRepresentable {
    var tabCardFrames: [ObjectIdentifier: CGRect]
    var onBlankSpaceDoubleClick: () -> Void
    var onTabDoubleClick: (ObjectIdentifier) -> Void

    func makeNSView(context: Context) -> DoubleClickView {
        DoubleClickView(
            tabCardFrames: tabCardFrames,
            onBlankSpaceDoubleClick: onBlankSpaceDoubleClick,
            onTabDoubleClick: onTabDoubleClick
        )
    }

    func updateNSView(_ nsView: DoubleClickView, context: Context) {
        nsView.tabCardFrames = tabCardFrames
        nsView.onBlankSpaceDoubleClick = onBlankSpaceDoubleClick
        nsView.onTabDoubleClick = onTabDoubleClick
    }

    class DoubleClickView: NSView {
        var tabCardFrames: [ObjectIdentifier: CGRect]
        var onBlankSpaceDoubleClick: () -> Void
        var onTabDoubleClick: (ObjectIdentifier) -> Void
        private var eventMonitor: Any?

        init(
            tabCardFrames: [ObjectIdentifier: CGRect],
            onBlankSpaceDoubleClick: @escaping () -> Void,
            onTabDoubleClick: @escaping (ObjectIdentifier) -> Void
        ) {
            self.tabCardFrames = tabCardFrames
            self.onBlankSpaceDoubleClick = onBlankSpaceDoubleClick
            self.onTabDoubleClick = onTabDoubleClick
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil && eventMonitor == nil {
                eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                    self?.handleMouseDown(event)
                    return event
                }
            } else if window == nil, let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
        }

        private func handleMouseDown(_ event: NSEvent) {
            guard event.clickCount == 2,
                  let myWindow = self.window,
                  myWindow.isKeyWindow,
                  event.window === myWindow else { return }
            let locationInView = convert(event.locationInWindow, from: nil)
            guard bounds.contains(locationInView) else { return }

            if let (tabID, _) = tabCardFrames.first(where: { $0.value.contains(locationInView) }) {
                onTabDoubleClick(tabID)
            } else {
                onBlankSpaceDoubleClick()
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            return nil
        }

        deinit {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

// MARK: - PulsingDot

/// Animated pulsing dot indicator.
struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 8
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(isPulsing ? 0.3 : 1.0)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}
