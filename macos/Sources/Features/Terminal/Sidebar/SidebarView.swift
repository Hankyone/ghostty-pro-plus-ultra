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

// MARK: - Drag & Drop Support

/// Where a dragged tab would be inserted: above or below a target row.
private struct TabDropTarget: Equatable {
    let id: ObjectIdentifier
    let below: Bool
}

/// Where a dragged project group would be inserted: above or below a target group.
private struct GroupDropTarget: Equatable {
    let id: String
    let below: Bool
}

/// Drag state shared by every sidebar instance.
///
/// Each tab window hosts its own sidebar. A drag can cross those view trees,
/// so keeping the state in one shared object keeps validation and indicators
/// in sync for the whole AppKit tab group.
private final class SidebarDragState: ObservableObject {
    static let shared = SidebarDragState()
    @Published var draggingTabID: ObjectIdentifier?
    @Published var draggingGroupID: String?
    @Published var tabDropTarget: TabDropTarget?
    @Published var groupDropTarget: GroupDropTarget?
    /// Incremented at every drag start so cleanup belongs to one session.
    @Published var dragGeneration = 0
}

/// An NSItemProvider that fires a callback when the drag session ends.
/// SwiftUI has no drag-cancelled callback, so without this the
/// "dragging" state (dimmed rows, insertion lines) sticks around forever
/// when a drag is dropped outside any valid target or cancelled with Esc.
/// The system releases the provider when the session ends, so deinit is
/// the reliable end-of-session signal.
private final class SidebarDragItemProvider: NSItemProvider {
    var onSessionEnd: (() -> Void)?

    deinit {
        if let onSessionEnd {
            DispatchQueue.main.async(execute: onSessionEnd)
        }
    }
}

/// The accent-colored insertion line shown while dragging.
private struct DropIndicator: View {
    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 2)
    }
}

// MARK: - SidebarView

/// A vertical sidebar that displays tabs grouped by project, styled after T3 Code.
struct SidebarView: View {
    @ObservedObject var tabManager: SidebarTabManager
    @ObservedObject var updateViewModel: UpdateViewModel
    var theme: SidebarTheme
    var fields: Set<SidebarField> = SidebarField.defaultFields

    @ObservedObject private var dragState = SidebarDragState.shared
    @State private var hoveredTabID: ObjectIdentifier?
    @State private var hoveredGroupID: String?
    @State private var tabCardFrames = SidebarCardFrames()
    fileprivate static let scrollCoordinateSpace = "SidebarScrollCoordinateSpace"

    private var isDragActive: Bool {
        dragState.draggingTabID != nil || dragState.draggingGroupID != nil
    }

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
                        draggingTabID: $dragState.draggingTabID,
                        draggingGroupID: $dragState.draggingGroupID,
                        tabDropTarget: $dragState.tabDropTarget,
                        groupDropTarget: $dragState.groupDropTarget,
                        dragGeneration: $dragState.dragGeneration,
                        hoveredTabID: $hoveredTabID,
                        hoveredGroupID: $hoveredGroupID,
                        isCollapsed: tabManager.collapsedProjects.contains(group.id)
                    )
                    .opacity(dragState.draggingGroupID == group.id ? 0.4 : 1.0)
                    .overlay(alignment: .top) {
                        if dragState.groupDropTarget == GroupDropTarget(id: group.id, below: false) {
                            DropIndicator().offset(y: -1)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if dragState.groupDropTarget == GroupDropTarget(id: group.id, below: true) {
                            DropIndicator().offset(y: 1)
                        }
                    }
                    .onDrop(of: [UTType.text], delegate: ProjectGroupDropDelegate(
                        tabManager: tabManager,
                        currentGroup: group,
                        draggingTabID: $dragState.draggingTabID,
                        draggingGroupID: $dragState.draggingGroupID,
                        tabDropTarget: $dragState.tabDropTarget,
                        groupDropTarget: $dragState.groupDropTarget
                    ))
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
        }
        .coordinateSpace(name: Self.scrollCoordinateSpace)
        .clipped()
        .windowDragIfAvailable()
        .task(id: dragState.dragGeneration) {
            // Watchdog for drag state. The normal end-of-drag signal is the
            // system releasing the drag's NSItemProvider, but the pasteboard
            // can retain it long after the session ends, leaving rows dimmed.
            // The mouse button is authoritative — a drag session cannot
            // outlive it — so clear the state shortly after it's released.
            // Keying this task by generation cancels an older drag's pending
            // cleanup whenever a new drag starts, including the same item.
            guard isDragActive else { return }
            let generation = dragState.dragGeneration
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 200_000_000)
                } catch {
                    return
                }
                guard generation == dragState.dragGeneration else { return }
                if NSEvent.pressedMouseButtons == 0 {
                    // Give a pending performDrop a moment to run first.
                    do {
                        try await Task.sleep(nanoseconds: 300_000_000)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled,
                          generation == dragState.dragGeneration else { return }
                    dragState.draggingTabID = nil
                    dragState.draggingGroupID = nil
                    dragState.tabDropTarget = nil
                    dragState.groupDropTarget = nil
                    return
                }
            }
        }
        // Written into a box rather than SwiftUI state on purpose. Row frames
        // change on every frame of a collapse or scroll, and publishing them
        // re-evaluated the whole sidebar each time — which is what made
        // collapsing feel heavy regardless of how many tabs were in the group.
        // Nothing draws from these; the click overlay reads them when a click
        // actually arrives.
        .onPreferenceChange(SidebarCardFramePreferenceKey.self) { tabCardFrames.value = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.clear)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if !updateViewModel.state.isIdle {
                    HStack {
                        Spacer()
                        UpdatePill(model: updateViewModel)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }

                HStack(spacing: 0) {
                    SidebarSettingsMenu(tabManager: tabManager, theme: theme)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .overlay(SidebarClickOverlay(
            frames: tabCardFrames,
            onBlankSpaceDoubleClick: { tabManager.createNewTab(projectRoot: NSHomeDirectory()) },
            onTabDoubleClick: { tabID in
                if let tab = tabManager.tabs.first(where: { $0.id == tabID }) {
                    tabManager.promptRenameTab(tab)
                }
            },
            onTabMiddleClick: { tabID in
                if let tab = tabManager.tabs.first(where: { $0.id == tabID }) {
                    tabManager.closeTab(tab)
                }
            }
        ))
    }
}

// MARK: - ProjectSection

/// A collapsible section for a project group with T3 Code-style vertical line indicator.
private struct ProjectSection: View {
    /// Shared by the section and its chevron so the header and the rows move
    /// on one clock. Short on purpose — a disclosure is an acknowledgement,
    /// not a scene change, and anything longer starts to read as hesitation.
    static let collapseAnimation: Animation = .easeOut(duration: 0.13)

    let group: SidebarTabManager.ProjectGroup
    @ObservedObject var tabManager: SidebarTabManager
    let theme: SidebarTheme
    let fields: Set<SidebarField>
    @Binding var draggingTabID: ObjectIdentifier?
    @Binding var draggingGroupID: String?
    @Binding var tabDropTarget: TabDropTarget?
    @Binding var groupDropTarget: GroupDropTarget?
    @Binding var dragGeneration: Int
    @Binding var hoveredTabID: ObjectIdentifier?
    @Binding var hoveredGroupID: String?
    let isCollapsed: Bool

    /// Creates a drag item provider that resets all drag state when the
    /// system drag session ends — including cancelled drags, for which
    /// SwiftUI provides no other callback.
    private func makeDragProvider(payload: String) -> NSItemProvider {
        let provider = SidebarDragItemProvider(object: payload as NSString)
        let draggingTab = $draggingTabID
        let draggingGroup = $draggingGroupID
        let tabTarget = $tabDropTarget
        let groupTarget = $groupDropTarget
        let generation = $dragGeneration
        let sessionGeneration = dragGeneration
        provider.onSessionEnd = {
            // A provider from an older drag may be released after a new drag
            // starts. It must never clear the newer session's shared state.
            guard generation.wrappedValue == sessionGeneration else { return }
            draggingTab.wrappedValue = nil
            draggingGroup.wrappedValue = nil
            tabTarget.wrappedValue = nil
            groupTarget.wrappedValue = nil
        }
        return provider
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Project header
            Button {
                // One animation for the whole change, driven from here so the
                // groups below this one move in step with it rather than
                // snapping into their new positions.
                withAnimation(Self.collapseAnimation) {
                    tabManager.toggleProjectCollapsed(group.id)
                }
            } label: {
                ProjectHeader(
                    group: group,
                    theme: theme,
                    isCollapsed: isCollapsed,
                    isHovered: hoveredGroupID == group.id,
                    onNewTab: { agent in
                        tabManager.createNewTab(agent: agent, projectRoot: group.launchDirectory)
                    },
                    onGitCommit: group.projectRoot != nil ? {
                        tabManager.gitCommit(projectRoot: group.projectRoot!)
                    } : nil,
                    onGitPush: group.projectRoot != nil ? {
                        tabManager.gitPush(projectRoot: group.projectRoot!)
                    } : nil,
                    onGitCommitAndPush: group.projectRoot != nil ? {
                        tabManager.gitCommitAndPush(projectRoot: group.projectRoot!)
                    } : nil,
                    gitActionStatus: tabManager.gitActionStatus(forProjectRoot: group.projectRoot)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovering in
                hoveredGroupID = isHovering ? group.id : nil
            }
            // The group drag handle is the header ONLY. Attaching .onDrag to
            // the whole section nests it around the tab rows' own .onDrag,
            // and the system may resolve that ambiguity to the outer (group)
            // drag — making it impossible to drag individual tabs.
            .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 6))
            .if(!group.isOtherGroup && !group.isHomeGroup) { view in
                view.onDrag {
                    draggingTabID = nil
                    tabDropTarget = nil
                    groupDropTarget = nil
                    draggingGroupID = group.id
                    dragGeneration += 1
                    return makeDragProvider(payload: group.id)
                }
            }

            // Thread list with vertical line indicator
            if !isCollapsed {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(group.tabs) { tab in
                        ThreadRow(
                            tab: tab,
                            isSelected: tab.id == tabManager.selectedTabID,
                            isHovered: hoveredTabID == tab.id,
                            isDragging: draggingTabID == tab.id,
                            dropAbove: tabDropTarget == TabDropTarget(id: tab.id, below: false),
                            dropBelow: tabDropTarget == TabDropTarget(id: tab.id, below: true),
                            activityLabel: tab.lastActivity.map(relativeTime),
                            theme: theme,
                            groupID: group.id,
                            tabManager: tabManager,
                            makeDragProvider: { makeDragProvider(payload: $0) },
                            hoveredTabID: $hoveredTabID,
                            draggingTabID: $draggingTabID,
                            draggingGroupID: $draggingGroupID,
                            tabDropTarget: $tabDropTarget,
                            groupDropTarget: $groupDropTarget,
                            dragGeneration: $dragGeneration
                        )
                    }

                    // A real target after the final row makes the otherwise
                    // empty trailing area an explicit "move to end" drop zone.
                    Color.clear
                        .frame(height: 10)
                        .contentShape(Rectangle())
                        .onDrop(of: [UTType.text], delegate: TabTrailingDropDelegate(
                            tabManager: tabManager,
                            currentGroup: group,
                            draggingTabID: $draggingTabID,
                            draggingGroupID: $draggingGroupID,
                            tabDropTarget: $tabDropTarget,
                            groupDropTarget: $groupDropTarget
                        ))
                }
                .padding(.leading, 6)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(theme.foreground.opacity(0.06))
                        .frame(width: 1)
                }
                .padding(.leading, 4)
                // Fade only, both directions. The section's height is already
                // animating; sliding the rows at the same time is a second
                // motion competing with the first, which is what made opening
                // feel heavier than closing. Sliding on the way out also
                // overflowed the rows past the top of the sidebar.
                .transition(.opacity)
            }
        }
        .padding(.bottom, 2)
    }

}

// MARK: - ThreadRow

/// A single tab row in the sidebar.
///
/// Kept as a normal SwiftUI view so each render installs a drop delegate with
/// the current drag bindings and tab identity. This interaction path is not a
/// safe place for an equality optimization that can retain an older delegate.
private struct ThreadRow: View {
    let tab: SidebarTabManager.TabItem
    let isSelected: Bool
    let isHovered: Bool
    let isDragging: Bool
    let dropAbove: Bool
    let dropBelow: Bool
    let activityLabel: String?
    let theme: SidebarTheme
    let groupID: String
    let tabManager: SidebarTabManager
    let makeDragProvider: (String) -> NSItemProvider
    @Binding var hoveredTabID: ObjectIdentifier?
    @Binding var draggingTabID: ObjectIdentifier?
    @Binding var draggingGroupID: String?
    @Binding var tabDropTarget: TabDropTarget?
    @Binding var groupDropTarget: GroupDropTarget?
    @Binding var dragGeneration: Int

    /// Whether the unread-notification subtitle line is showing; the row
    /// grows to two lines when it is.
    private var subtitleVisible: Bool {
        !isSelected && tab.notificationText != nil
    }

    /// Hover text for the activity mark. The tool name is the useful part —
    /// it is the difference between "busy" and "running your test suite".
    private func activityDescription(_ activity: AgentTranscriptWatcher.Activity) -> String {
        switch activity {
        case .thinking: return "Thinking"
        case .tool(let name): return "Running \(name)"
        case .working: return "Working"
        case .needsInput: return "Waiting for you"
        case .idle: return ""
        }
    }

    var body: some View {
        let titleColor = isSelected || isHovered ? theme.foreground : theme.secondaryText
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
            // Status dot — leading position. A pulse strictly means "this
            // tab needs you"; everything else is solid or absent.
            if tab.indicator == .needsInput {
                PulsingDot(color: .orange, size: 6).padding(.trailing, 6)
            } else if tab.needsAttention && !isSelected {
                // Bell / desktop notification / IPC notify.
                PulsingDot(color: theme.attentionColor, size: 6).padding(.trailing, 6)
            } else if let activity = tab.activity, activity != .idle {
                // The transcript knows more than the dot does, so let it say
                // so: reasoning, running a tool, or simply mid-turn.
                ActivityMark(activity: activity)
                    .frame(width: 7, height: 7)
                    .padding(.trailing, 6)
                    .help(activityDescription(activity))
            } else {
                switch tab.indicator {
                case .doneUnseen:
                    Circle().fill(.green).frame(width: 6, height: 6).padding(.trailing, 6)
                case .error:
                    Circle().fill(.red).frame(width: 6, height: 6).padding(.trailing, 6)
                case .working:
                    Circle().fill(Color.accentColor).frame(width: 5, height: 5).padding(.trailing, 6)
                case .needsInput, .none:
                    EmptyView()
                }
            }

            // Title, with the latest desktop-notification text as a subtitle
            // while unread (cmux-style — e.g. Devin's "Devin finished ...").
            let primaryTitle = tab.displayTitle
            let subtitle: String? = subtitleVisible ? tab.notificationText : nil

            VStack(alignment: .leading, spacing: 1) {
                Text(primaryTitle)
                    .font(.system(size: 11))
                    .foregroundColor(titleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(primaryTitle)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(theme.attentionColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(subtitle)
                }
            }

            // Relative time — "3m", "1h" (time since last real activity)
            if let activityLabel {
                Text(activityLabel)
                    .font(.system(size: 9))
                    .foregroundColor(theme.secondaryText.opacity(0.5))
                    .fixedSize()
            }
        }
        .frame(height: subtitleVisible ? 42 : 28)
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
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 6))
        .onDrag {
            draggingGroupID = nil
            tabDropTarget = nil
            groupDropTarget = nil
            draggingTabID = tab.id
            dragGeneration += 1
            return makeDragProvider(tab.surfaceId?.uuidString ?? "tab")
        }
        .onDrop(of: [UTType.text], delegate: TabDropDelegate(
            tabManager: tabManager,
            currentTab: tab,
            groupID: groupID,
            draggingTabID: $draggingTabID,
            draggingGroupID: $draggingGroupID,
            tabDropTarget: $tabDropTarget,
            groupDropTarget: $groupDropTarget
        ))
        .opacity(isDragging ? 0.4 : 1.0)
        .overlay(alignment: .top) {
            if dropAbove {
                DropIndicator().offset(y: -1)
            }
        }
        .overlay(alignment: .bottom) {
            if dropBelow {
                DropIndicator().offset(y: 1)
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
                    NSWorkspace.shared.open(URL(fileURLWithPath: (pwd as NSString).expandingTildeInPath))
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
    /// Called to open a new tab. A nil agent opens a plain terminal.
    var onNewTab: ((SidebarTabManager.AgentType?) -> Void)? = nil
    @ObservedObject private var agentDetector = AgentDetector.shared
    var onGitCommit: (() -> Void)? = nil
    var onGitPush: (() -> Void)? = nil
    var onGitCommitAndPush: (() -> Void)? = nil
    var gitActionStatus: SidebarTabManager.GitActionStatus? = nil
    @State private var isNewTabHovered = false

    private var gitActionInProgress: Bool {
        gitActionStatus == .inProgress
    }

    var body: some View {
        HStack(spacing: 6) {
            // Collapse chevron — 14px, rotates 90° on expand
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.secondaryText.opacity(0.7))
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .animation(ProjectSection.collapseAnimation, value: isCollapsed)
                .frame(width: 14, height: 14)

            // Favicon or folder icon
            if let favicon = group.faviconImage {
                Image(nsImage: favicon)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .frame(width: 16, height: 16)
            } else if group.isHomeGroup {
                Image(systemName: "house.fill")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
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

            // Git action status indicator (spinner / error)
            if case .inProgress = gitActionStatus {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
            } else if case .error(let message) = gitActionStatus {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .help(message)
            }

            // Git diff stats
            if let stats = group.gitDiffStats, gitActionStatus != .inProgress {
                Text(stats)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
            }

            if let onNewTab {
                Menu {
                    // Terminal — standalone option
                    Button {
                        onNewTab(nil)
                    } label: {
                        Label("Terminal", systemImage: "terminal")
                            .labelStyle(.titleAndIcon)
                    }

                    // Coding agents — only the ones actually installed.
                    let installedAgents = SidebarTabManager.AgentType.allCases
                        .filter { agentDetector.installed.contains($0) }
                    if !installedAgents.isEmpty {
                        Divider()
                        ForEach(installedAgents, id: \.self) { agent in
                            Button {
                                onNewTab(agent)
                            } label: {
                                Label {
                                    Text(agent.displayName)
                                } icon: {
                                    AgentMenuIcon(agent: agent)
                                }
                                .labelStyle(.titleAndIcon)
                            }
                        }
                    }

                    // Git actions (only for real project groups)
                    if let onGitCommit, let onGitPush, let onGitCommitAndPush {
                        Divider()
                        Button {
                            onGitCommit()
                        } label: {
                            Label(
                                gitActionInProgress ? "Working..." : "Commit",
                                systemImage: "checkmark.circle"
                            )
                            .labelStyle(.titleAndIcon)
                        }
                        .disabled(gitActionInProgress || group.gitDiffStats == nil)

                        Button {
                            onGitPush()
                        } label: {
                            Label(
                                gitActionInProgress ? "Working..." : "Push",
                                systemImage: "arrow.up.circle"
                            )
                            .labelStyle(.titleAndIcon)
                        }
                        .disabled(gitActionInProgress)

                        Button {
                            onGitCommitAndPush()
                        } label: {
                            Label(
                                gitActionInProgress ? "Working..." : "Commit & Push",
                                systemImage: "arrow.up.circle.fill"
                            )
                            .labelStyle(.titleAndIcon)
                        }
                        .disabled(gitActionInProgress || group.gitDiffStats == nil)
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
                .id(gitActionStatus == .inProgress)
                // Deliberately not `.borderlessButton`: that legacy style drops
                // the artwork on every item in the menu it presents, which
                // silently blanked all the icons below. `.button` + a plain
                // button style keeps the chrome-free look without that.
                .menuStyle(.button)
                .buttonStyle(.plain)
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

private struct AgentMenuIcon: View {
    let agent: SidebarTabManager.AgentType

    var body: some View {
        if let image = Self.menuImage(named: agent.icon) {
            Image(nsImage: image)
        } else {
            // Missing asset: fall back to a generic glyph rather than a gap.
            Image(systemName: "chevron.left.forwardslash.chevron.right")
        }
    }

    /// A menu row sizes its artwork from the image itself — SwiftUI's frame and
    /// resizing modifiers are dropped when the item crosses into the native
    /// menu — so hand back a copy that already carries the right size. The
    /// asset's own template intent is preserved so single-color marks pick up
    /// the menu's text color while the full-color ones stay full-color.
    private static func menuImage(named name: String) -> NSImage? {
        guard let source = NSImage(named: name) else { return nil }
        guard let copy = source.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: 14, height: 14)
        copy.isTemplate = source.isTemplate
        return copy
    }
}

// MARK: - ProjectGroupDropDelegate

/// Handles drops on a whole project section: accepts group drags
/// (reordering projects) and rejects everything else. Tab drags over the
/// rows themselves are handled by the rows' own TabDropDelegate.
private struct ProjectGroupDropDelegate: DropDelegate {
    let tabManager: SidebarTabManager
    let currentGroup: SidebarTabManager.ProjectGroup
    @Binding var draggingTabID: ObjectIdentifier?
    @Binding var draggingGroupID: String?
    @Binding var tabDropTarget: TabDropTarget?
    @Binding var groupDropTarget: GroupDropTarget?

    /// The "Home" and "Other" groups are always pinned last, so they can
    /// neither be moved nor serve as a reorder target.
    private var isValidGroupDrag: Bool {
        guard let draggingGroupID else { return false }
        return draggingGroupID != currentGroup.id
            && !currentGroup.isOtherGroup && !currentGroup.isHomeGroup
    }

    /// Whether the move would land the dragged group below the target.
    /// moveProjectGroup() inserts after the target when dragging down and
    /// before it when dragging up, so the indicator must match.
    private var insertsBelow: Bool {
        guard let draggingGroupID else { return false }
        let groups = tabManager.projectGroups
        guard let from = groups.firstIndex(where: { $0.id == draggingGroupID }),
              let to = groups.firstIndex(where: { $0.id == currentGroup.id })
        else { return false }
        return from < to
    }

    func dropEntered(info: DropInfo) {
        if isValidGroupDrag {
            groupDropTarget = GroupDropTarget(id: currentGroup.id, below: insertsBelow)
        }
    }

    func dropExited(info: DropInfo) {
        if groupDropTarget?.id == currentGroup.id {
            groupDropTarget = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard isValidGroupDrag else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        isValidGroupDrag
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggingTabID = nil
            draggingGroupID = nil
            tabDropTarget = nil
            groupDropTarget = nil
        }
        guard isValidGroupDrag, let draggingGroupID else { return false }

        // Switch to manual sort mode and perform the move
        tabManager.setProjectSortMode(.manual)
        tabManager.moveProjectGroup(fromId: draggingGroupID, toId: currentGroup.id)
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

/// Handles drops on an individual tab row. Tab drags reorder within the
/// same project (with above/below insertion based on cursor position).
/// Group drags are forwarded to group-reorder semantics so that hovering
/// anywhere over a section — header or rows — targets the whole group.
private struct TabDropDelegate: DropDelegate {
    /// Row height of a tab row; used to decide above/below insertion.
    private static let rowHeight: CGFloat = 28
    /// Height when the row shows an unread-notification subtitle line.
    private static let tallRowHeight: CGFloat = 42

    /// The actual height of this row right now, so the above/below midpoint
    /// stays correct while a notification subtitle is showing.
    private var currentRowHeight: CGFloat {
        currentTab.notificationText == nil ? Self.rowHeight : Self.tallRowHeight
    }

    let tabManager: SidebarTabManager
    let currentTab: SidebarTabManager.TabItem
    let groupID: String
    @Binding var draggingTabID: ObjectIdentifier?
    @Binding var draggingGroupID: String?
    @Binding var tabDropTarget: TabDropTarget?
    @Binding var groupDropTarget: GroupDropTarget?

    private var isGroupDrag: Bool { draggingGroupID != nil }

    /// The group ID of the tab being dragged. Uses the tab's own `groupID` so
    /// it matches `buildProjectGroups` exactly — including the "__home__" case,
    /// which the old `projectRoot ?? "__other__"` derivation got wrong (it
    /// classified Home tabs as "__other__", breaking within-Home reordering and
    /// wrongly permitting Home→Other drops).
    private var draggingTabGroupID: String? {
        guard let id = draggingTabID,
              let tab = tabManager.tabs.first(where: { $0.id == id })
        else { return nil }
        return tab.groupID
    }

    private var isValidGroupDrag: Bool {
        guard let draggingGroupID else { return false }
        // Home and Other are pinned pseudo-groups and can't be reordered onto,
        // matching ProjectGroupDropDelegate's own guard.
        return draggingGroupID != groupID
            && groupID != "__other__"
            && groupID != "__home__"
    }

    /// Tab drags are restricted to reordering within the same project.
    private var isValidTabDrag: Bool {
        draggingTabID != nil && draggingTabID != currentTab.id && draggingTabGroupID == groupID
    }

    /// See ProjectGroupDropDelegate.insertsBelow.
    private var groupInsertsBelow: Bool {
        guard let draggingGroupID else { return false }
        let groups = tabManager.projectGroups
        guard let from = groups.firstIndex(where: { $0.id == draggingGroupID }),
              let to = groups.firstIndex(where: { $0.id == groupID })
        else { return false }
        return from < to
    }

    private func updateTarget(_ info: DropInfo) {
        // `dropUpdated` fires continuously while the mouse moves, so only
        // publish when the target actually changes. Reassigning the same
        // @Published value re-renders the whole sidebar on every mouse-move
        // event, which is what made dragging stutter while the insertion line
        // was showing.
        if isGroupDrag {
            if isValidGroupDrag {
                let newTarget = GroupDropTarget(id: groupID, below: groupInsertsBelow)
                if groupDropTarget != newTarget { groupDropTarget = newTarget }
            }
        } else if isValidTabDrag {
            let newTarget = TabDropTarget(
                id: currentTab.id,
                below: info.location.y >= currentRowHeight / 2
            )
            if tabDropTarget != newTarget { tabDropTarget = newTarget }
        }
    }

    func dropEntered(info: DropInfo) {
        updateTarget(info)
    }

    func dropExited(info: DropInfo) {
        if tabDropTarget?.id == currentTab.id {
            tabDropTarget = nil
        }
        if isGroupDrag, groupDropTarget?.id == groupID {
            groupDropTarget = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard isValidGroupDrag || isValidTabDrag else {
            return DropProposal(operation: .forbidden)
        }
        updateTarget(info)
        return DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        isValidGroupDrag || isValidTabDrag
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggingTabID = nil
            draggingGroupID = nil
            tabDropTarget = nil
            groupDropTarget = nil
        }

        // Group drag dropped over a tab row: reorder the groups.
        if isGroupDrag {
            guard isValidGroupDrag, let draggingGroupID else { return false }
            tabManager.setProjectSortMode(.manual)
            tabManager.moveProjectGroup(fromId: draggingGroupID, toId: groupID)
            return true
        }

        // Tab reorder. Keep identities intact across the drop boundary; the
        // manager derives the single AppKit/persistence order from them.
        guard isValidTabDrag,
              let draggingTabID,
              let movingTab = tabManager.tabs.first(where: { $0.id == draggingTabID })
        else { return false }

        // Compute the insertion side from the actual drop location, relative to
        // this row (the same row `targetIndex` resolves to). Reading it from the
        // shared `tabDropTarget` was unreliable: SwiftUI fires `dropExited` on
        // the hovered row right before `performDrop`, clearing `tabDropTarget`
        // to nil, so `?? false` defaulted every such drop to "above" — which is
        // exactly why "below" insertions silently failed.
        let below = info.location.y >= currentRowHeight / 2
        // Manual arrangement implies manual sort mode, same as group reorder —
        // in the activity/creation sort modes the displayed order ignores the
        // underlying tab order, so the drop would otherwise appear to do nothing.
        if tabManager.projectSortMode != .manual {
            tabManager.setProjectSortMode(.manual)
        }
        tabManager.moveTab(
            movingTab,
            relativeTo: currentTab,
            position: below ? .after : .before
        )
        return true
    }
}

// MARK: - TabTrailingDropDelegate

/// Accepts a same-group tab in the small trailing area after the final row.
/// Group drags continue through to the section-level group delegate.
private struct TabTrailingDropDelegate: DropDelegate {
    let tabManager: SidebarTabManager
    let currentGroup: SidebarTabManager.ProjectGroup
    @Binding var draggingTabID: ObjectIdentifier?
    @Binding var draggingGroupID: String?
    @Binding var tabDropTarget: TabDropTarget?
    @Binding var groupDropTarget: GroupDropTarget?

    private var movingTab: SidebarTabManager.TabItem? {
        guard draggingGroupID == nil, let draggingTabID else { return nil }
        return tabManager.tabs.first(where: { $0.id == draggingTabID })
    }

    private var targetTab: SidebarTabManager.TabItem? {
        guard let movingTab else { return nil }
        return currentGroup.tabs.last(where: { $0.id != movingTab.id })
    }

    private var isValidTabDrag: Bool {
        movingTab?.groupID == currentGroup.id && targetTab != nil
    }

    private func updateTarget() {
        guard isValidTabDrag, let lastTab = currentGroup.tabs.last else { return }
        // Only publish on change — dropUpdated fires on every mouse-move and
        // reassigning the same @Published target re-renders the whole sidebar.
        let newTarget = TabDropTarget(id: lastTab.id, below: true)
        if tabDropTarget != newTarget { tabDropTarget = newTarget }
    }

    func dropEntered(info: DropInfo) {
        updateTarget()
    }

    func dropExited(info: DropInfo) {
        if let lastTab = currentGroup.tabs.last,
           tabDropTarget == TabDropTarget(id: lastTab.id, below: true) {
            tabDropTarget = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard isValidTabDrag else { return DropProposal(operation: .forbidden) }
        updateTarget()
        return DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        isValidTabDrag
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggingTabID = nil
            draggingGroupID = nil
            tabDropTarget = nil
            groupDropTarget = nil
        }
        guard let movingTab, let targetTab, isValidTabDrag else { return false }

        if tabManager.projectSortMode != .manual {
            tabManager.setProjectSortMode(.manual)
        }
        tabManager.moveTab(movingTab, relativeTo: targetTab, position: .after)
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
/// Where each tab row currently sits, for hit-testing clicks.
///
/// Deliberately a reference type held outside SwiftUI's dependency graph:
/// these change continuously while the sidebar animates, and nothing on
/// screen is drawn from them, so a view has no business being invalidated
/// when they move. Main thread only, like everything else in the sidebar.
private final class SidebarCardFrames: @unchecked Sendable {
    var value: [ObjectIdentifier: CGRect] = [:]
}

private struct SidebarCardFramePreferenceKey: PreferenceKey {
    static var defaultValue: [ObjectIdentifier: CGRect] = [:]

    static func reduce(value: inout [ObjectIdentifier: CGRect], nextValue: () -> [ObjectIdentifier: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// MARK: - SidebarClickOverlay

/// Transparent NSView overlay that recognizes double-click and middle-click
/// actions without taking pointer events away from SwiftUI. Single-click
/// selection stays on the row's mouse-up tap so pressing a nonselected row can
/// become a drag without replacing its hosting window mid-gesture.
///
/// One overlay for the whole sidebar, not one per row. Every AppKit view
/// embedded in SwiftUI has to be repositioned individually on each frame of an
/// animation, so a per-row view multiplies that cost by the number of rows —
/// which is precisely what made collapsing a group drag down everything below
/// it. This view already knows where each row sits, so it can answer for all
/// of them.
private struct SidebarClickOverlay: NSViewRepresentable {
    var frames: SidebarCardFrames
    var onBlankSpaceDoubleClick: () -> Void
    var onTabDoubleClick: (ObjectIdentifier) -> Void
    var onTabMiddleClick: (ObjectIdentifier) -> Void

    func makeNSView(context: Context) -> ClickView {
        ClickView(
            frames: frames,
            onBlankSpaceDoubleClick: onBlankSpaceDoubleClick,
            onTabDoubleClick: onTabDoubleClick,
            onTabMiddleClick: onTabMiddleClick
        )
    }

    func updateNSView(_ nsView: ClickView, context: Context) {
        nsView.frames = frames
        nsView.onBlankSpaceDoubleClick = onBlankSpaceDoubleClick
        nsView.onTabDoubleClick = onTabDoubleClick
        nsView.onTabMiddleClick = onTabMiddleClick
    }

    class ClickView: NSView {
        var frames: SidebarCardFrames
        var onBlankSpaceDoubleClick: () -> Void
        var onTabDoubleClick: (ObjectIdentifier) -> Void
        var onTabMiddleClick: (ObjectIdentifier) -> Void
        private var eventMonitor: Any?
        /// Timestamp of the last handled double-click, used to debounce
        /// duplicate events that can arrive when multiple sidebar hosting
        /// views (one per tab in the tab group) briefly have overlapping
        /// event monitors during window key-state transitions.
        private var lastHandledClickTime: TimeInterval = 0

        init(
            frames: SidebarCardFrames,
            onBlankSpaceDoubleClick: @escaping () -> Void,
            onTabDoubleClick: @escaping (ObjectIdentifier) -> Void,
            onTabMiddleClick: @escaping (ObjectIdentifier) -> Void
        ) {
            self.frames = frames
            self.onBlankSpaceDoubleClick = onBlankSpaceDoubleClick
            self.onTabDoubleClick = onTabDoubleClick
            self.onTabMiddleClick = onTabMiddleClick
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil && eventMonitor == nil {
                eventMonitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.leftMouseDown, .otherMouseUp]
                ) { [weak self] event in
                    if event.type == .otherMouseUp {
                        self?.handleMiddleMouseUp(event)
                    } else {
                        self?.handleMouseDown(event)
                    }
                    return event
                }
            } else if window == nil, let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
        }

        private func handleMouseDown(_ event: NSEvent) {
            guard let myWindow = self.window,
                  myWindow.isKeyWindow,
                  event.window === myWindow else { return }

            let locationInView = convert(event.locationInWindow, from: nil)
            guard bounds.contains(locationInView) else { return }

            let hitTab = frames.value.first(where: { $0.value.contains(locationInView) })?.key

            guard event.clickCount == 2 else { return }
            // Debounce: ignore double-clicks within 400ms of a previously
            // handled one. Multiple sidebar monitors can observe the same
            // event during the key-window transition that follows tab
            // creation, causing createNewTab to fire twice.
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastHandledClickTime < 0.4 { return }
            lastHandledClickTime = now

            if let hitTab {
                onTabDoubleClick(hitTab)
            } else {
                onBlankSpaceDoubleClick()
            }
        }

        /// Middle-click closes the row under the pointer. Blank space is
        /// ignored — there's nothing there to close.
        private func handleMiddleMouseUp(_ event: NSEvent) {
            guard event.buttonNumber == 2,
                  let myWindow = self.window,
                  myWindow.isKeyWindow,
                  event.window === myWindow else { return }

            let locationInView = convert(event.locationInWindow, from: nil)
            guard bounds.contains(locationInView) else { return }

            guard let hitTab = frames.value.first(
                where: { $0.value.contains(locationInView) }
            )?.key else { return }
            onTabMiddleClick(hitTab)
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
///
/// The pulse is driven by a Core Animation layer animation rather than a
/// SwiftUI `.repeatForever` opacity animation. A repeating SwiftUI animation
/// forces `NSHostingView.layout()` to re-render the *entire* sidebar display
/// list on every display cycle — walking every tab row just to update one dot's
/// opacity. That is an O(rows) per-frame cost on the main thread that scales
/// with tab count and pegs the CPU whenever any tab shows a live dot. A CALayer
/// `opacity` animation runs entirely on the render server / GPU and never
/// re-enters SwiftUI or AppKit layout, so the cost is independent of tab count.
struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 8
    /// Draw the ring only. A filled dot says "here"; an open one says the
    /// agent is turning something over and hasn't acted yet.
    var hollow: Bool = false

    var body: some View {
        PulsingDotLayer(color: color, hollow: hollow)
            .frame(width: size, height: size)
    }
}

/// The leading mark for a tab whose agent is mid-turn.
///
/// It stays inside the vocabulary the sidebar already uses — a small mark in
/// the same 6pt slot — and varies its form rather than reaching for an icon
/// set, so a row never changes width and the three states read as one family.
struct ActivityMark: View {
    let activity: AgentTranscriptWatcher.Activity

    var body: some View {
        switch activity {
        case .thinking:
            // Open and breathing: considering, not yet doing.
            PulsingDot(color: .accentColor, size: 7, hollow: true)
        case .tool:
            // Square and still: acting on something definite.
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.accentColor)
                .frame(width: 5, height: 5)
        case .needsInput:
            // Same orange pulse the hook-driven path uses, so "you're needed"
            // looks identical no matter which agent noticed it.
            PulsingDot(color: .orange, size: 6)
        case .working, .idle:
            Circle().fill(Color.accentColor).frame(width: 5, height: 5)
        }
    }
}

/// Hosts a layer-backed `NSView` whose backing layer pulses its opacity via
/// Core Animation. See `PulsingDot` for why this is not a SwiftUI animation.
private struct PulsingDotLayer: NSViewRepresentable {
    let color: Color
    var hollow: Bool = false

    func makeNSView(context: Context) -> PulsingDotNSView {
        PulsingDotNSView(color: NSColor(color), hollow: hollow)
    }

    func updateNSView(_ nsView: PulsingDotNSView, context: Context) {
        nsView.updateColor(NSColor(color))
    }

    final class PulsingDotNSView: NSView {
        private let hollow: Bool

        init(color: NSColor, hollow: Bool = false) {
            self.hollow = hollow
            super.init(frame: .zero)
            wantsLayer = true
            if hollow {
                layer?.backgroundColor = NSColor.clear.cgColor
                layer?.borderColor = color.cgColor
                layer?.borderWidth = 1.5
            } else {
                layer?.backgroundColor = color.cgColor
            }

            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.3
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(pulse, forKey: "pulse")
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            // Keep the dot circular for whatever size SwiftUI assigns.
            layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        }

        func updateColor(_ color: NSColor) {
            if hollow {
                layer?.borderColor = color.cgColor
            } else {
                layer?.backgroundColor = color.cgColor
            }
        }
    }
}
