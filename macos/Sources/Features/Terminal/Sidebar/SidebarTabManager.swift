import Cocoa
import Combine
import os.log

/// Per-window façade over `SidebarStore` that publishes tab metadata for
/// one window's sidebar.
///
/// All discovery, caching, and rebuild work happens once, app-wide, in
/// `SidebarStore`. This class only holds the published slice for its
/// window's tab group, the selection state, and the user-action entry
/// points (select/close/move/git/...). One instance exists per tab window
/// because each tab window hosts its own sidebar view.
@MainActor
class SidebarTabManager: ObservableObject {
    private static let orderLog = Logger(
        subsystem: "com.hankyone.ghostty.sidebar", category: "order")

    /// What the tab's status dot should communicate. Ordered by priority.
    ///
    /// Display convention (matching the strongest patterns across T3 Code,
    /// Conductor, Emdash, cmux): a dot **pulses only when the tab needs the
    /// user** — everything else is solid or absent. "Done" and "failed" are
    /// gated on *unseen* and clear when the tab is visited.
    enum TabIndicator: Equatable, Hashable {
        /// An agent is waiting for input/approval — pulsing orange.
        case needsInput
        /// A run finished and the user hasn't looked yet — solid green.
        case doneUnseen
        /// A command/agent run failed and the user hasn't looked — solid red.
        case error
        /// Agent or foreground process is busy — small solid accent dot.
        case working
        /// Nothing worth showing.
        case none
    }

    struct TabItem: Identifiable, Equatable {
        let id: ObjectIdentifier
        let title: String
        let pwd: String?
        let gitDiffStats: String?
        let surfaceId: UUID?
        let statusEntries: [TabMetadataStore.StatusEntry]
        let needsAttention: Bool
        /// True when the tab has a completion that hasn't been viewed yet.
        let hasUnreadCompletion: Bool
        let tabColor: TerminalTabColor
        let faviconImage: NSImage?
        let window: NSWindow
        /// The detected project root directory for this tab, or nil if not in a project.
        let projectRoot: String?
        /// When this tab last had real activity (command execution, status change).
        var lastActivity: Date?
        /// When this tab was first created (persisted across restarts).
        var createdAt: Date?
        /// What the status dot should show. Computed by the store from
        /// hooks, OSC signals, and the screen-quiescence classifier.
        var indicator: TabIndicator = .none

        /// The last path component of the pwd, for compact display.
        var directoryName: String? {
            guard let pwd, !pwd.isEmpty else { return nil }
            return ((pwd as NSString).expandingTildeInPath as NSString).lastPathComponent
        }

        /// Title with bell/ghost emoji stripped for clean sidebar display.
        var displayTitle: String {
            var t = title
            // Strip bell emoji prefix (sidebar has its own attention indicator)
            if t.hasPrefix("\u{1F514} ") { t = String(t.dropFirst(3)) }
            // Strip ghost emoji prefix (default Ghostty window title)
            if t.hasPrefix("\u{1F47B} ") { t = String(t.dropFirst(3)) }
            // If title is just "Ghostty" or empty after stripping, use directory name
            if t.isEmpty || t == "Ghostty" {
                if let dir = directoryName { return dir }
            }
            return t
        }

        static func == (lhs: TabItem, rhs: TabItem) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title
                && lhs.pwd == rhs.pwd && lhs.gitDiffStats == rhs.gitDiffStats
                && lhs.surfaceId == rhs.surfaceId
                && lhs.statusEntries == rhs.statusEntries
                && lhs.needsAttention == rhs.needsAttention
                && lhs.hasUnreadCompletion == rhs.hasUnreadCompletion
                && lhs.tabColor == rhs.tabColor
                && lhs.faviconImage === rhs.faviconImage
                && lhs.projectRoot == rhs.projectRoot
                && lhs.lastActivity == rhs.lastActivity
                && lhs.indicator == rhs.indicator
        }
    }

    /// A group of tabs sharing the same project root.
    struct ProjectGroup: Identifiable, Equatable {
        let id: String  // projectRoot path, "__home__", or "__other__" for ungrouped
        let name: String
        let projectRoot: String?
        let tabs: [TabItem]
        let faviconImage: NSImage?
        /// Aggregated git diff stats across all tabs in this project.
        let gitDiffStats: String?

        /// Whether this is the "Other" group for ungrouped tabs.
        var isOtherGroup: Bool { id == "__other__" }

        /// Whether this is the Home group for tabs in the home directory.
        var isHomeGroup: Bool { id == "__home__" }

        static func == (lhs: ProjectGroup, rhs: ProjectGroup) -> Bool {
            lhs.id == rhs.id && lhs.name == rhs.name
                && lhs.tabs == rhs.tabs
                && lhs.faviconImage === rhs.faviconImage
                && lhs.gitDiffStats == rhs.gitDiffStats
        }
    }

    enum SortMode: String, CaseIterable {
        case manual = "Manual"
        case createdAt = "Created at"
        case lastActivity = "Last activity"
    }

    enum GitActionStatus: Equatable {
        case inProgress
        case error(String)
    }

    // MARK: - Published State

    @Published private(set) var tabs: [TabItem] = []
    @Published private(set) var projectGroups: [ProjectGroup] = []
    @Published var selectedTabID: ObjectIdentifier?
    @Published private(set) var collapsedProjects: Set<String> = []

    private(set) weak var window: NSWindow?
    private(set) var isInvalidated = false

    /// Guard flag: when true, notification-driven refreshSelection() calls are
    /// suppressed so they don't overwrite the optimistic selectedTabID that
    /// selectTab() just set. The tabGroup.selectedWindow setter fires key-window
    /// notifications synchronously during assignment, and at that point the tab
    /// group's selectedWindow can return intermediate (old) state.
    private var isSelectingTab = false

    private var store: SidebarStore { SidebarStore.shared }

    init(window: NSWindow, bellTriggersAttention: Bool = true) {
        self.window = window
        SidebarStore.shared.register(self, bellTriggersAttention: bellTriggersAttention)
        refreshSelection()
    }

    /// Break all window references when the owning tab closes.
    ///
    /// Every `TabItem` contains a strong reference to its window. Leaving
    /// those references in a closed tab's manager keeps its terminal
    /// controller, surface tree, and PTY alive after the tab disappears.
    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        store.unregister(self)
        tabs.removeAll()
        projectGroups.removeAll()
        selectedTabID = nil
    }

    deinit {
        // Store holds only a weak reference; nothing to tear down here.
    }

    // MARK: - Store Callbacks

    /// Whether the given window belongs to the same tab group as ours.
    func isInSameTabGroup(as other: NSWindow) -> Bool {
        guard let window else { return false }
        if let group = window.tabGroup {
            return other.tabGroup === group
        }
        return other === window
    }

    /// Receive a freshly built slice from the store. Publishes only on change.
    func apply(
        tabs newTabs: [TabItem],
        projectGroups newGroups: [ProjectGroup],
        collapsed: Set<String>,
        republishForTimeLabels: Bool = false
    ) {
        guard !isInvalidated else { return }
        let tabsChanged = newTabs != tabs
        if tabsChanged {
            tabs = newTabs
        }
        if newGroups != projectGroups {
            projectGroups = newGroups
        } else if !tabsChanged && republishForTimeLabels {
            // Data identical, but relative-time labels ("3m") rendered from
            // it are stale — poke SwiftUI without touching the arrays.
            objectWillChange.send()
        }
        if collapsed != collapsedProjects {
            collapsedProjects = collapsed
        }
        refreshSelection()
    }

    func applyCollapsed(_ collapsed: Set<String>) {
        guard !isInvalidated else { return }
        if collapsed != collapsedProjects {
            collapsedProjects = collapsed
        }
    }

    /// The store's git action state changed; re-render.
    func noteGitActionChanged() {
        guard !isInvalidated else { return }
        objectWillChange.send()
    }

    // MARK: - Selection

    /// Lightweight update that only syncs `selectedTabID` from the window's
    /// tab group, without rebuilding anything.
    func refreshSelection() {
        guard !isInvalidated else { return }
        guard !isSelectingTab else { return }
        guard let window else { return }
        let selectedWindow = window.tabGroup?.selectedWindow ?? window
        let newID = ObjectIdentifier(selectedWindow)
        if selectedTabID != newID {
            selectedTabID = newID
        }
    }

    func selectTab(_ tab: TabItem) {
        Self.orderLog.info("selectTab: \(tab.displayTitle, privacy: .public) win#\(tab.window.windowNumber)")

        // Don't rebuild here — the next store refresh picks up the
        // attention/acknowledgment changes.
        store.clearAttentionOnSelect(windowID: tab.id)
        acknowledgeCompletion(for: tab)
        selectedTabID = tab.id
        // Guard against notification-driven refreshSelection() calls that fire
        // synchronously during the tabGroup.selectedWindow setter. Without this,
        // those handlers read intermediate state and revert our optimistic update.
        isSelectingTab = true
        if let window,
           let tabGroup = window.tabGroup,
           tabGroup.windows.contains(tab.window) {
            tabGroup.selectedWindow = tab.window
        } else {
            tab.window.makeKeyAndOrderFront(nil)
        }
        isSelectingTab = false

        // After the setter, the target window's sidebar is now visible to the user.
        // Its manager's refreshSelection may have run during the setter and read
        // intermediate (old) state. Correct it now that the setter has completed.
        if let targetController = tab.window.windowController as? TerminalController,
           let targetManager = targetController.sidebarTabManager,
           targetManager !== self {
            targetManager.selectedTabID = tab.id
        }
    }

    /// Acknowledge the current completion token for a tab so its green dot stops pulsing.
    private func acknowledgeCompletion(for tab: TabItem) {
        guard let sid = tab.surfaceId else { return }
        guard let agent = AgentType.detect(from: tab.statusEntries) else { return }
        guard let token = tab.statusEntries.first(where: { $0.key == agent.doneAtKey })?.value else { return }
        TabMetadataStore.shared.acknowledgedDoneToken[sid] = token
    }

    // MARK: - Refresh

    func refresh() {
        guard !isInvalidated else { return }
        store.requestRefresh(reason: "manual", force: true)
    }

    // MARK: - Sorting & Grouping passthroughs

    var projectSortMode: SortMode { store.projectSortMode }

    func setProjectSortMode(_ mode: SortMode) {
        store.projectSortMode = mode
    }

    func toggleProjectCollapsed(_ groupId: String) {
        store.toggleProjectCollapsed(groupId)
    }

    func moveProjectGroup(fromId: String, toId: String) {
        store.moveProjectGroup(fromId: fromId, toId: toId, currentGroups: projectGroups)
    }

    // MARK: - Git Actions passthroughs

    func gitCommit(projectRoot: String) { store.gitCommit(projectRoot: projectRoot) }
    func gitPush(projectRoot: String) { store.gitPush(projectRoot: projectRoot) }
    func gitCommitAndPush(projectRoot: String) { store.gitCommitAndPush(projectRoot: projectRoot) }

    func gitActionStatus(forProjectRoot root: String?) -> GitActionStatus? {
        store.gitActionStatus(forProjectRoot: root)
    }

    // MARK: - Tool Launch

    /// The CLI tools that can be auto-launched in a new tab.
    enum SidebarTool: String, CaseIterable {
        case terminal = "Terminal"
        case claudeCode = "Claude Code"
        case codex = "Codex"
        case grok = "Grok Build"
        case devin = "Devin"
        case cursor = "Cursor"
        case antigravity = "Antigravity"

        var icon: String {
            switch self {
            case .terminal: return "terminal"
            case .claudeCode: return "ClaudeIcon"
            case .codex: return "CodexIcon"
            case .grok: return "GrokIcon"
            case .devin: return "DevinIcon"
            case .cursor: return "CursorIcon"
            case .antigravity: return "AntigravityIcon"
            }
        }

        var isCustomIcon: Bool {
            switch self {
            case .terminal: return false
            case .claudeCode, .codex, .grok, .devin, .cursor, .antigravity: return true
            }
        }

        /// The shell command to launch this tool.
        var launchCommand: String? {
            switch self {
            case .terminal: return nil
            case .claudeCode: return "claude --dangerously-skip-permissions"
            case .codex: return "codex --dangerously-bypass-approvals-and-sandbox"
            case .grok: return "grok --permission-mode bypassPermissions"
            case .devin: return "devin --permission-mode dangerous"
            case .cursor: return "cursor-agent --yolo"
            case .antigravity: return "agy --dangerously-skip-permissions"
            }
        }
    }

    /// Represents an AI agent that can be tracked in the sidebar.
    /// Each agent has a set of status keys used by its hook script.
    enum AgentType: String, CaseIterable {
        case claude
        case codex
        case grok
        case devin
        case cursor

        /// The session key (e.g. "claude-session"). Presence of this key
        /// indicates the tab is running this agent.
        var sessionKey: String { "\(rawValue)-session" }

        /// The active status key (e.g. "claude-active"). Values: "working", "done", "needs-input".
        var activeKey: String { "\(rawValue)-active" }

        /// The PID key (e.g. "claude-pid"). Used for stale session detection.
        var pidKey: String { "\(rawValue)-pid" }

        /// The completion token key (e.g. "claude-done-at"). A UUID emitted on Stop.
        var doneAtKey: String { "\(rawValue)-done-at" }

        /// The prompt text key (e.g. "claude"). Holds the truncated last user prompt.
        var promptKey: String { rawValue }

        /// Detect which agent is running for a set of status entries.
        /// Returns the first matching agent (agents are mutually exclusive).
        static func detect(from entries: [TabMetadataStore.StatusEntry]) -> AgentType? {
            for agent in allCases {
                if entries.contains(where: { $0.key == agent.sessionKey }) {
                    return agent
                }
            }
            return nil
        }
    }

    /// Create a new tab, optionally in a project directory and/or running a tool.
    func createNewTab(tool: SidebarTool = .terminal, projectRoot: String? = nil) {
        guard let window,
              let controller = window.windowController as? TerminalController else {
            // Fallback: create a generic new tab
            NSApp.sendAction(#selector(TerminalController.newTab(_:)), to: nil, from: nil)
            return
        }

        var config = Ghostty.SurfaceConfiguration()
        if let root = projectRoot {
            config.workingDirectory = root
        }
        // Set the tool command as initialInput — this is fed directly into
        // the PTY as stdin data, so the shell reads and executes it as if
        // the user typed it and pressed Enter.
        if let command = tool.launchCommand {
            config.initialInput = command + "\n"
        }

        _ = TerminalController.newTab(
            controller.ghostty,
            from: window,
            withBaseConfig: config
        )
    }

    // MARK: - Tab Actions

    func createNewTab() {
        NSApp.sendAction(#selector(TerminalController.newTab(_:)), to: nil, from: nil)
    }

    func setTabColor(_ color: TerminalTabColor, for tab: TabItem) {
        (tab.window as? TerminalWindow)?.tabColor = color
        refresh()
    }

    func closeTab(_ tab: TabItem) {
        guard let controller = tab.window.windowController as? TerminalController else { return }
        if let surfaceId = tab.surfaceId?.uuidString {
            store.removeTabsFromManualOrder([surfaceId])
        }
        controller.closeTab(nil)
    }

    func renameTab(_ tab: TabItem, to newTitle: String) {
        guard let controller = tab.window.windowController as? BaseTerminalController else { return }
        controller.titleOverride = newTitle.isEmpty ? nil : newTitle
        refresh()
    }

    func promptRenameTab(_ tab: TabItem) {
        guard let controller = tab.window.windowController as? BaseTerminalController else { return }
        controller.promptTabTitle()
    }

    func closeOtherTabs(_ tab: TabItem) {
        guard let window else { return }
        let tabWindows = store.orderedTabWindows(for: window)
        guard tabWindows.count > 1 else { return }
        let idsToRemove = tabWindows
            .filter { ObjectIdentifier($0) != tab.id }
            .compactMap { store.tabOrderKey(for: $0) }
        store.removeTabsFromManualOrder(idsToRemove)
        for w in tabWindows where ObjectIdentifier(w) != tab.id {
            if let controller = w.windowController as? TerminalController {
                controller.closeTab(nil)
            }
        }
    }

    func closeTabsToTheRight(of tab: TabItem) {
        guard let window else { return }
        let tabWindows = store.orderedTabWindows(for: window)
        guard tabWindows.count > 1 else { return }
        guard let idx = tabWindows.firstIndex(where: { ObjectIdentifier($0) == tab.id }) else { return }
        let tabsToClose = Array(tabWindows[(idx + 1)...])
        store.removeTabsFromManualOrder(tabsToClose.compactMap { store.tabOrderKey(for: $0) })
        for w in tabsToClose {
            if let controller = w.windowController as? TerminalController {
                controller.closeTab(nil)
            }
        }
    }

    func moveTab(from sourceIndex: Int, to destinationIndex: Int) {
        Self.orderLog.info("moveTab from \(sourceIndex) to \(destinationIndex)")

        guard let window else { return }
        let tabbedWindows = store.orderedTabWindows(for: window)
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < tabbedWindows.count,
              destinationIndex >= 0, destinationIndex < tabbedWindows.count else { return }

        let movingWindow = tabbedWindows[sourceIndex]
        let targetWindow = tabbedWindows[destinationIndex]

        let reorderedGroupIds: [String]? = {
            let ids = tabbedWindows.compactMap { store.tabOrderKey(for: $0) }
            guard ids.count == tabbedWindows.count else { return nil }
            var reordered = ids
            let moved = reordered.remove(at: sourceIndex)
            reordered.insert(moved, at: destinationIndex)
            return reordered
        }()

        if sourceIndex > destinationIndex {
            targetWindow.addTabbedWindow(movingWindow, ordered: .below)
        } else {
            targetWindow.addTabbedWindow(movingWindow, ordered: .above)
        }

        if let reorderedGroupIds {
            store.persistTabOrder(reorderedGroupIds, for: tabbedWindows)
        }

        if let selectedWindow = window.tabGroup?.selectedWindow {
            selectedWindow.makeKeyAndOrderFront(nil)
        }

        refresh()
    }
}
