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
        /// Latest desktop-notification text (OSC 9/777), shown as a row
        /// subtitle until the tab is selected. This is how agents without
        /// hooks (e.g. Devin) report "finished" — same source cmux shows.
        let notificationText: String?
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
        /// What the agent's own transcript says it is doing, when we can read
        /// one. Finer-grained than the dot: it names the tool and knows the
        /// difference between reasoning and acting.
        var activity: AgentTranscriptWatcher.Activity?

        /// The last path component of the pwd, for compact display.
        var directoryName: String? {
            guard let pwd, !pwd.isEmpty else { return nil }
            return ((pwd as NSString).expandingTildeInPath as NSString).lastPathComponent
        }

        /// Title with bell/ghost emoji stripped for clean sidebar display.
        var displayTitle: String {
            var t = title
            // Strip bell emoji prefix (sidebar has its own attention indicator)
            // and ghost emoji prefix (default Ghostty window title). Note:
            // dropFirst counts Characters, so each emoji+space prefix is 2.
            for prefix in ["\u{1F514} ", "\u{1F47B} "] {
                if t.hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)) }
            }
            // If title is just "Ghostty" or empty after stripping, use directory name
            if t.isEmpty || t == "Ghostty" {
                if let dir = directoryName { return dir }
            }
            return t
        }

        /// The id of the display group this tab belongs to: a project root path,
        /// or "__home__" / "__other__". Single source of truth for group
        /// membership — used by both `SidebarStore.buildProjectGroups` and the
        /// drag-and-drop validator so grouping and drop-eligibility can never
        /// disagree (a mismatch previously broke Home-group reordering).
        var groupID: String {
            if let projectRoot { return projectRoot }
            if let pwd, (pwd as NSString).expandingTildeInPath == NSHomeDirectory() {
                return "__home__"
            }
            return "__other__"
        }

        static func == (lhs: TabItem, rhs: TabItem) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title
                && lhs.pwd == rhs.pwd && lhs.gitDiffStats == rhs.gitDiffStats
                && lhs.surfaceId == rhs.surfaceId
                && lhs.statusEntries == rhs.statusEntries
                && lhs.needsAttention == rhs.needsAttention
                && lhs.notificationText == rhs.notificationText
                && lhs.hasUnreadCompletion == rhs.hasUnreadCompletion
                && lhs.tabColor == rhs.tabColor
                && lhs.faviconImage === rhs.faviconImage
                && lhs.projectRoot == rhs.projectRoot
                && lhs.lastActivity == rhs.lastActivity
                && lhs.indicator == rhs.indicator
                && lhs.activity == rhs.activity
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

        /// Where a terminal launched from this group's header should open.
        ///
        /// Home has no project root, but it does have an obvious folder, and
        /// falling through to "wherever the last tab happened to be" is the
        /// one answer nobody means when they click the header that says Home.
        /// Other stays inherited: it is a bag of unrelated directories, so
        /// there is nothing to point at.
        var launchDirectory: String? {
            if let projectRoot { return projectRoot }
            return isHomeGroup ? NSHomeDirectory() : nil
        }

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
        // Only publish when the value actually changes. `@Published` fires on
        // every assignment, even to an equal value.
        if selectedTabID != tab.id { selectedTabID = tab.id }
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
           targetManager !== self,
           targetManager.selectedTabID != tab.id {
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

    /// Represents a coding agent the sidebar knows about — the single source
    /// of truth for both the new-tab menu and status/session tracking.
    ///
    /// To add an agent, add a case here and fill in the switches below; the
    /// menu, installed-detection, launch, resume, status keys, transient-key
    /// filtering and stale-session sweep all derive from `allCases`.
    ///
    /// `rawValue` is the internal key prefix used by the hook IPC protocol
    /// (e.g. `claude-session`) and must stay stable — it is NOT the display
    /// name and NOT necessarily the binary name.
    enum AgentType: String, CaseIterable {
        case claude
        case codex
        case opencode
        case grok
        case devin
        case cursor
        case antigravity
        case cline

        /// Human-facing name shown in the new-tab menu.
        var displayName: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            case .opencode: return "OpenCode"
            case .grok: return "Grok Build"
            case .devin: return "Devin"
            case .cursor: return "Cursor"
            case .antigravity: return "Antigravity"
            case .cline: return "Cline"
            }
        }

        /// The executable name to look for on the user's PATH. This can differ
        /// from both the display name and the rawValue key prefix.
        var binaryName: String {
            switch self {
            case .claude: return "claude"
            case .codex: return "codex"
            case .opencode: return "opencode"
            case .grok: return "grok"
            case .devin: return "devin"
            case .cursor: return "cursor-agent"
            case .antigravity: return "agy"
            case .cline: return "cline"
            }
        }

        /// Asset-catalog image name for the agent's official menu mark.
        var icon: String {
            switch self {
            case .claude: return "ClaudeIcon"
            case .codex: return "CodexIcon"
            case .opencode: return "OpenCodeIcon"
            case .grok: return "GrokIcon"
            case .devin: return "DevinIcon"
            case .cursor: return "CursorIcon"
            case .antigravity: return "AntigravityIcon"
            case .cline: return "ClineIcon"
            }
        }

        /// Flags that launch the agent with permissions fully bypassed (yolo).
        private var permissionFlags: String {
            switch self {
            case .claude: return "--dangerously-skip-permissions"
            case .codex: return "--dangerously-bypass-approvals-and-sandbox"
            case .opencode: return "--auto"
            case .grok: return "--permission-mode bypassPermissions"
            case .devin: return "--permission-mode dangerous"
            case .cursor: return "--yolo"
            case .antigravity: return "--dangerously-skip-permissions"
            // Cline needs -i for its interactive TUI (bare `cline` runs a
            // single non-interactive prompt); auto-approve is on by default
            // but we pass it explicitly to be safe.
            case .cline: return "-i --auto-approve true"
            }
        }

        /// The shell command to launch a fresh session of this agent.
        var launchCommand: String {
            "\(binaryName) \(permissionFlags)"
        }

        /// The shell command to resume a prior session, or nil if resume isn't
        /// supported. `sessionId` is the stored value of `sessionKey`.
        func resumeCommand(sessionId: String) -> String? {
            // Guard against command injection: session ids are typed straight
            // into the shell, so only allow a safe charset.
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            let idIsSafe = sessionId.unicodeScalars.allSatisfy { allowed.contains($0) }
            switch self {
            case .claude:
                guard idIsSafe else { return nil }
                return "claude --resume \(sessionId) \(permissionFlags)"
            case .codex:
                guard idIsSafe else { return nil }
                return "codex resume \(sessionId) \(permissionFlags)"
            case .grok:
                guard idIsSafe else { return nil }
                return "grok --resume \(sessionId) \(permissionFlags)"
            case .cursor:
                guard idIsSafe else { return nil }
                return "cursor-agent --resume \(sessionId) \(permissionFlags)"
            case .devin:
                // Devin exposes no session id in hooks, so there's nothing to
                // validate — launch its interactive session picker instead.
                return "devin -r \(permissionFlags)"
            case .opencode, .antigravity, .cline:
                // No hook-provided session id / resume support yet.
                return nil
            }
        }

        /// The session key (e.g. "claude-session"). Presence of this key
        /// indicates the tab is running this agent.
        var sessionKey: String { "\(rawValue)-session" }

        /// Whether this agent's own record of the conversation is readable.
        ///
        /// For these, silence is information: it means the agent has not
        /// started a turn yet, not that we are in the dark. Guessing a state
        /// from the shape of the screen on top of that is how a freshly
        /// opened agent sitting at its own prompt ends up demanding
        /// attention it does not want.
        var hasDirectStatus: Bool {
            switch self {
            case .claude, .codex, .grok, .opencode, .devin, .cline: return true
            case .cursor, .antigravity: return false
            }
        }

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

    /// Create a new tab, optionally in a project directory and/or running an
    /// agent. A nil `agent` opens a plain terminal.
    func createNewTab(agent: AgentType? = nil, projectRoot: String? = nil) {
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
        // Set the agent command as initialInput — this is fed directly into
        // the PTY as stdin data, so the shell reads and executes it as if
        // the user typed it and pressed Enter.
        if let command = agent?.launchCommand {
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
        controller.closeTab(nil)
    }

    /// The window shown directly above `window` in the sidebar, or the one
    /// below it when `window` is the very first row. Nil if it's the only tab.
    ///
    /// Used to choose which tab takes over when the visible one closes.
    func tabAdjacentInDisplayOrder(to window: NSWindow) -> NSWindow? {
        let ordered = projectGroups.flatMap(\.tabs)
        let id = ObjectIdentifier(window)
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return nil }
        if index > 0 { return ordered[index - 1].window }
        return ordered.count > 1 ? ordered[1].window : nil
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
        for w in tabsToClose {
            if let controller = w.windowController as? TerminalController {
                controller.closeTab(nil)
            }
        }
    }

    enum TabInsertionPosition: Equatable {
        case before
        case after
    }

    /// Reorder one tab relative to another by identity.
    ///
    /// The sidebar display groups tabs by project, while AppKit and the
    /// persisted order are a flat window list. Keeping integer indices across
    /// those two spaces is unsafe, so the drop boundary passes stable window
    /// identities and this method derives one desired flat order used by both
    /// AppKit and persistence.
    @discardableResult
    func moveTab(
        _ movingTab: TabItem,
        relativeTo targetTab: TabItem,
        position: TabInsertionPosition
    ) -> Bool {
        Self.orderLog.info(
            "moveTab win#\(movingTab.window.windowNumber) \(position == .before ? "before" : "after") win#\(targetTab.window.windowNumber)")

        guard movingTab.id != targetTab.id,
              movingTab.groupID == targetTab.groupID,
              let window else { return false }

        let currentWindows = store.orderedTabWindows(for: window)
        guard let sourceIndex = currentWindows.firstIndex(where: {
            ObjectIdentifier($0) == movingTab.id
        }), currentWindows.contains(where: {
            ObjectIdentifier($0) == targetTab.id
        }) else { return false }

        let movingWindow = currentWindows[sourceIndex]
        var desiredWindows = currentWindows
        desiredWindows.remove(at: sourceIndex)

        guard let targetIndex = desiredWindows.firstIndex(where: {
            ObjectIdentifier($0) == targetTab.id
        }) else { return false }
        let insertionIndex = position == .before ? targetIndex : targetIndex + 1
        desiredWindows.insert(movingWindow, at: insertionIndex)

        guard desiredWindows.map(ObjectIdentifier.init) != currentWindows.map(ObjectIdentifier.init)
        else { return false }

        // Capture the visible member before AppKit mutates the tab group.
        let selectedWindow = window.tabGroup?.selectedWindow ?? window
        let preMoveFrame = selectedWindow.frame

        // Position the moving window against its neighbor in the final order.
        // AppKit's `.below` inserts before the receiver and `.above` after it.
        if insertionIndex == 0 {
            desiredWindows[1].addTabbedWindow(movingWindow, ordered: .below)
        } else {
            desiredWindows[insertionIndex - 1].addTabbedWindow(movingWindow, ordered: .above)
        }

        let reorderedIds = desiredWindows.compactMap { store.tabOrderKey(for: $0) }
        if reorderedIds.count == desiredWindows.count {
            store.persistTabOrder(reorderedIds, for: currentWindows)
        }

        // A macOS tab group renders a single shared frame (the key window's).
        // Reordering via addTabbedWindow + makeKeyAndOrderFront can make the
        // group adopt the re-inserted/newly-key window's own cascade-offset
        // origin, teleporting the whole visible window on drop. Capture the
        // current on-screen frame and restore it afterward so the window stays
        // put. (Same teleport class the showWindow secondary-tab guard prevents.)
        if let tabGroup = window.tabGroup,
           tabGroup.windows.contains(selectedWindow) {
            tabGroup.selectedWindow = selectedWindow
        }
        if selectedWindow.tabGroup?.windows.contains(selectedWindow) == true || selectedWindow === window {
            selectedWindow.makeKeyAndOrderFront(nil)
            if selectedWindow.frame != preMoveFrame {
                selectedWindow.setFrame(preMoveFrame, display: true)
            }
        }

        refresh()
        return true
    }
}
