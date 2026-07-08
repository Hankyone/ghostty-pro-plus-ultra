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
/// Each tab window hosts its own sidebar. Selecting a tab on mouse-down can
/// switch the visible window at the very start of a drag, so the sidebar
/// that *started* the drag (in the now-hidden window) and the sidebar that
/// shows drop indicators (in the newly visible window) are different view
/// trees. Keeping the drag state in one shared object keeps them in sync.
private final class SidebarDragState: ObservableObject {
    static let shared = SidebarDragState()
    @Published var draggingTabID: ObjectIdentifier?
    @Published var draggingGroupID: String?
    @Published var tabDropTarget: TabDropTarget?
    @Published var groupDropTarget: GroupDropTarget?
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
    @State private var tabCardFrames: [ObjectIdentifier: CGRect] = [:]
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
                        hoveredTabID: $hoveredTabID,
                        hoveredGroupID: $hoveredGroupID,
                        tabCardFrames: $tabCardFrames,
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
        .task(id: isDragActive) {
            // Watchdog for drag state. The normal end-of-drag signal is the
            // system releasing the drag's NSItemProvider, but the pasteboard
            // can retain it long after the session ends, leaving rows dimmed.
            // The mouse button is authoritative — a drag session cannot
            // outlive it — so clear the state shortly after it's released.
            guard isDragActive else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if NSEvent.pressedMouseButtons == 0 {
                    // Give a pending performDrop a moment to run first.
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    dragState.draggingTabID = nil
                    dragState.draggingGroupID = nil
                    dragState.tabDropTarget = nil
                    dragState.groupDropTarget = nil
                    return
                }
            }
        }
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
        .overlay(SidebarClickOverlay(
            tabCardFrames: tabCardFrames,
            onBlankSpaceDoubleClick: { tabManager.createNewTab(projectRoot: NSHomeDirectory()) },
            onTabDoubleClick: { tabID in
                if let tab = tabManager.tabs.first(where: { $0.id == tabID }) {
                    tabManager.promptRenameTab(tab)
                }
            },
            onTabMouseDown: { tabID in
                // Select on mouse-DOWN for a native, snappy feel. The row's
                // tap gesture still fires on mouse-up as a no-op fallback
                // (and covers clicks that activate a non-key window).
                if let tab = tabManager.tabs.first(where: { $0.id == tabID }),
                   tab.id != tabManager.selectedTabID {
                    tabManager.selectTab(tab)
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
    @Binding var draggingGroupID: String?
    @Binding var tabDropTarget: TabDropTarget?
    @Binding var groupDropTarget: GroupDropTarget?
    @Binding var hoveredTabID: ObjectIdentifier?
    @Binding var hoveredGroupID: String?
    @Binding var tabCardFrames: [ObjectIdentifier: CGRect]
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
        provider.onSessionEnd = {
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
                    draggingGroupID = group.id
                    return makeDragProvider(payload: group.id)
                }
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
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        // Removal (collapse): fade only, no upward slide.
                        // The slide causes content to overflow above the
                        // project header and past the sidebar's top edge.
                        removal: .opacity
                    )
                )
            }
        }
        .padding(.bottom, 2)
        .animation(.easeOut(duration: 0.18), value: isCollapsed)
    }

    @ViewBuilder
    private func threadRow(for tab: SidebarTabManager.TabItem) -> some View {
        let isSelected = tab.id == tabManager.selectedTabID
        let isHovered = hoveredTabID == tab.id
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

            // Title
            let primaryTitle = tab.displayTitle

            Text(primaryTitle)
                .font(.system(size: 11))
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
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 6))
        .onDrag {
            draggingTabID = tab.id
            return makeDragProvider(payload: tab.surfaceId?.uuidString ?? "tab")
        }
        .onDrop(of: [UTType.text], delegate: TabDropDelegate(
            tabManager: tabManager,
            currentTab: tab,
            groupID: group.id,
            draggingTabID: $draggingTabID,
            draggingGroupID: $draggingGroupID,
            tabDropTarget: $tabDropTarget,
            groupDropTarget: $groupDropTarget
        ))
        .opacity(draggingTabID == tab.id ? 0.4 : 1.0)
        .overlay(alignment: .top) {
            if tabDropTarget == TabDropTarget(id: tab.id, below: false) {
                DropIndicator().offset(y: -1)
            }
        }
        .overlay(alignment: .bottom) {
            if tabDropTarget == TabDropTarget(id: tab.id, below: true) {
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
    var onNewTab: ((SidebarTabManager.SidebarTool) -> Void)? = nil
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
                .animation(.easeInOut(duration: 0.15), value: isCollapsed)
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
                        onNewTab(.terminal)
                    } label: {
                        Label("Terminal", systemImage: "terminal")
                            .labelStyle(.titleAndIcon)
                    }

                    Divider()

                    // Coding agents
                    ForEach(SidebarTabManager.SidebarTool.allCases.filter { $0 != .terminal }, id: \.self) { tool in
                        Button {
                            onNewTab(tool)
                        } label: {
                            HStack(spacing: 6) {
                                SidebarToolMenuIcon(tool: tool)
                                Text(tool.rawValue)
                            }
                        }
                    }

                    // Git actions (only for real project groups)
                    if let onGitCommit, let onGitPush, let onGitCommitAndPush {
                        Divider()
                        Button {
                            onGitCommit()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 14, weight: .medium))
                                Text(gitActionInProgress ? "Working..." : "Commit")
                            }
                        }
                        .disabled(gitActionInProgress || group.gitDiffStats == nil)

                        Button {
                            onGitPush()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up.circle")
                                    .font(.system(size: 14, weight: .medium))
                                Text(gitActionInProgress ? "Working..." : "Push")
                            }
                        }
                        .disabled(gitActionInProgress)

                        Button {
                            onGitCommitAndPush()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 14, weight: .medium))
                                Text(gitActionInProgress ? "Working..." : "Commit & Push")
                            }
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
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .fixedSize(horizontal: true, vertical: true)
            } else {
                Image(systemName: tool.icon)
                    .font(.system(size: 14, weight: .medium))
            }
        }
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

    let tabManager: SidebarTabManager
    let currentTab: SidebarTabManager.TabItem
    let groupID: String
    @Binding var draggingTabID: ObjectIdentifier?
    @Binding var draggingGroupID: String?
    @Binding var tabDropTarget: TabDropTarget?
    @Binding var groupDropTarget: GroupDropTarget?

    private var isGroupDrag: Bool { draggingGroupID != nil }

    /// The group ID of the tab being dragged ("__other__" for ungrouped tabs).
    private var draggingTabGroupID: String? {
        guard let id = draggingTabID,
              let tab = tabManager.tabs.first(where: { $0.id == id })
        else { return nil }
        return tab.projectRoot ?? "__other__"
    }

    private var isValidGroupDrag: Bool {
        guard let draggingGroupID else { return false }
        return draggingGroupID != groupID && groupID != "__other__"
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
        if isGroupDrag {
            if isValidGroupDrag {
                groupDropTarget = GroupDropTarget(id: groupID, below: groupInsertsBelow)
            }
        } else if isValidTabDrag {
            tabDropTarget = TabDropTarget(
                id: currentTab.id,
                below: info.location.y >= Self.rowHeight / 2
            )
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
        let target = tabDropTarget
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

        // Tab reorder. Resolve indices by ID at drop time — indices captured
        // at drag start can go stale because the tab list refreshes during
        // the drag.
        guard isValidTabDrag,
              let draggingTabID,
              let source = tabManager.tabs.firstIndex(where: { $0.id == draggingTabID }),
              let targetIndex = tabManager.tabs.firstIndex(where: { $0.id == currentTab.id })
        else { return false }

        let below = target?.below ?? false
        let destination: Int = below
            ? (source < targetIndex ? targetIndex : targetIndex + 1)
            : (source < targetIndex ? targetIndex - 1 : targetIndex)

        // Manual arrangement implies manual sort mode, same as group reorder —
        // in the activity/creation sort modes the displayed order ignores the
        // underlying tab order, so the drop would otherwise appear to do nothing.
        if tabManager.projectSortMode != .manual {
            tabManager.setProjectSortMode(.manual)
        }
        if destination != source {
            tabManager.moveTab(from: source, to: destination)
        }
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

// MARK: - SidebarClickOverlay

/// Transparent NSView overlay that monitors click events via an event
/// monitor, bypassing SwiftUI's gesture system entirely.
///
/// Single clicks on a tab row select it on mouse-DOWN — SwiftUI's tap
/// gesture only fires on mouse-up, which reads as sluggish next to native
/// sidebars (Finder, Xcode) that all select on mouse-down. Double clicks
/// rename a tab or create a new tab on blank space.
private struct SidebarClickOverlay: NSViewRepresentable {
    var tabCardFrames: [ObjectIdentifier: CGRect]
    var onBlankSpaceDoubleClick: () -> Void
    var onTabDoubleClick: (ObjectIdentifier) -> Void
    var onTabMouseDown: (ObjectIdentifier) -> Void

    func makeNSView(context: Context) -> ClickView {
        ClickView(
            tabCardFrames: tabCardFrames,
            onBlankSpaceDoubleClick: onBlankSpaceDoubleClick,
            onTabDoubleClick: onTabDoubleClick,
            onTabMouseDown: onTabMouseDown
        )
    }

    func updateNSView(_ nsView: ClickView, context: Context) {
        nsView.tabCardFrames = tabCardFrames
        nsView.onBlankSpaceDoubleClick = onBlankSpaceDoubleClick
        nsView.onTabDoubleClick = onTabDoubleClick
        nsView.onTabMouseDown = onTabMouseDown
    }

    class ClickView: NSView {
        var tabCardFrames: [ObjectIdentifier: CGRect]
        var onBlankSpaceDoubleClick: () -> Void
        var onTabDoubleClick: (ObjectIdentifier) -> Void
        var onTabMouseDown: (ObjectIdentifier) -> Void
        private var eventMonitor: Any?
        /// Timestamp of the last handled double-click, used to debounce
        /// duplicate events that can arrive when multiple sidebar hosting
        /// views (one per tab in the tab group) briefly have overlapping
        /// event monitors during window key-state transitions.
        private var lastHandledClickTime: TimeInterval = 0

        init(
            tabCardFrames: [ObjectIdentifier: CGRect],
            onBlankSpaceDoubleClick: @escaping () -> Void,
            onTabDoubleClick: @escaping (ObjectIdentifier) -> Void,
            onTabMouseDown: @escaping (ObjectIdentifier) -> Void
        ) {
            self.tabCardFrames = tabCardFrames
            self.onBlankSpaceDoubleClick = onBlankSpaceDoubleClick
            self.onTabDoubleClick = onTabDoubleClick
            self.onTabMouseDown = onTabMouseDown
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
            guard let myWindow = self.window,
                  myWindow.isKeyWindow,
                  event.window === myWindow else { return }

            let locationInView = convert(event.locationInWindow, from: nil)
            guard bounds.contains(locationInView) else { return }

            let hitTab = tabCardFrames.first(where: { $0.value.contains(locationInView) })?.key

            // Single click on a tab: select immediately on mouse-down.
            // The event still propagates so drags keep working.
            if event.clickCount == 1 {
                if let hitTab {
                    onTabMouseDown(hitTab)
                }
                return
            }

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

    var body: some View {
        PulsingDotLayer(color: color)
            .frame(width: size, height: size)
    }
}

/// Hosts a layer-backed `NSView` whose backing layer pulses its opacity via
/// Core Animation. See `PulsingDot` for why this is not a SwiftUI animation.
private struct PulsingDotLayer: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> PulsingDotNSView {
        PulsingDotNSView(color: NSColor(color))
    }

    func updateNSView(_ nsView: PulsingDotNSView, context: Context) {
        nsView.updateColor(NSColor(color))
    }

    final class PulsingDotNSView: NSView {
        init(color: NSColor) {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = color.cgColor

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
            layer?.backgroundColor = color.cgColor
        }
    }
}
