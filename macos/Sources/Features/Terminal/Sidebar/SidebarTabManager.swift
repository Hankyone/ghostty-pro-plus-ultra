import Cocoa
import Combine
import UserNotifications

/// Observes the tab group of a window and publishes tab metadata for the sidebar.
@MainActor
class SidebarTabManager: ObservableObject {
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

        /// The last path component of the pwd, for compact display.
        var directoryName: String? {
            guard let pwd, !pwd.isEmpty else { return nil }
            return (pwd as NSString).lastPathComponent
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
        }
    }

    /// A group of tabs sharing the same project root.
    struct ProjectGroup: Identifiable, Equatable {
        let id: String  // projectRoot path, or "__other__" for ungrouped
        let name: String
        let projectRoot: String?
        let tabs: [TabItem]
        let faviconImage: NSImage?
        /// Aggregated git diff stats across all tabs in this project.
        let gitDiffStats: String?

        /// Whether this is the "Other" group for ungrouped tabs.
        var isOtherGroup: Bool { id == "__other__" }

        static func == (lhs: ProjectGroup, rhs: ProjectGroup) -> Bool {
            lhs.id == rhs.id && lhs.name == rhs.name
                && lhs.tabs == rhs.tabs
                && lhs.faviconImage === rhs.faviconImage
                && lhs.gitDiffStats == rhs.gitDiffStats
        }
    }

    @Published var tabs: [TabItem] = []
    @Published var projectGroups: [ProjectGroup] = []
    @Published var selectedTabID: ObjectIdentifier?

    /// Collapsed project group IDs, persisted to UserDefaults.
    /// Always reads from UserDefaults so all SidebarTabManager instances
    /// (one per tab window) stay in sync.
    @Published var collapsedProjects: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "SidebarCollapsedProjects") ?? []
    )

    func toggleProjectCollapsed(_ groupId: String) {
        if collapsedProjects.contains(groupId) {
            collapsedProjects.remove(groupId)
        } else {
            collapsedProjects.insert(groupId)
        }
        UserDefaults.standard.set(Array(collapsedProjects), forKey: "SidebarCollapsedProjects")
    }

    /// Re-sync collapsed state from UserDefaults (called during refresh
    /// so all tab managers agree on which projects are collapsed).
    private func syncCollapsedProjects() {
        let saved = Set(UserDefaults.standard.stringArray(forKey: "SidebarCollapsedProjects") ?? [])
        if saved != collapsedProjects {
            collapsedProjects = saved
        }
    }

    /// Windows that need attention, cleared when the tab is selected.
    private var attentionWindows: Set<ObjectIdentifier> = []

    /// Tracks the last-acknowledged completion token per surface UUID.
    /// When a tab's current done-at token differs from the acknowledged one,
    /// the green dot pulses to indicate an unread completion.
    private var acknowledgedDoneToken: [UUID: String] = [:]

    /// Whether bells should trigger the sidebar attention indicator.
    /// Derived from `bell-features` containing `attention`.
    private let bellTriggersAttention: Bool

    /// Cache of detected project roots keyed by pwd.
    /// Static so all SidebarTabManager instances share it.
    private static var projectRootCache: [String: String?] = [:]

    /// Cache of detected favicons keyed by pwd to avoid re-scanning every refresh.
    /// Static so all SidebarTabManager instances share it.
    private static var faviconCache: [String: NSImage?] = [:]

    /// Pwds currently being detected in the background, to avoid duplicate work.
    private static var faviconDetectionInFlight: Set<String> = []

    /// Shared FSEvents-based git stats watcher — all tab managers read from the
    /// same store so switching tabs never loses project-level stats.
    private var gitStatsWatcher: GitStatsWatcher { GitStatsWatcher.shared }

    /// Throttle for stale Claude PID sweeping (every 30s).
    private var lastPidSweepTime: Date = .distantPast
    private static let pidSweepInterval: TimeInterval = 30.0

    /// Fingerprint of the last timer-driven refresh, used to skip no-op rebuilds.
    private var lastRefreshFingerprint: Int = 0

    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    /// Guard flag: when true, notification-driven refreshSelection() calls are
    /// suppressed so they don't overwrite the optimistic selectedTabID that
    /// selectTab() just set. The tabGroup.selectedWindow setter fires key-window
    /// notifications synchronously during assignment, and at that point the tab
    /// group's selectedWindow can return intermediate (old) state.
    private var isSelectingTab = false

    init(window: NSWindow, bellTriggersAttention: Bool = true) {
        self.window = window
        self.bellTriggersAttention = bellTriggersAttention
        let observerId = ObjectIdentifier(self)
        gitStatsWatcher.addChangeObserver(id: observerId) { [weak self] in
            self?.refresh(reason: "git stats changed")
        }
        setupObservers()
        refresh(reason: "init")
    }

    deinit {
        timer?.invalidate()
        GitStatsWatcher.shared.removeChangeObserver(id: ObjectIdentifier(self))
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Returns the logical tab order for the current tab group.
    /// AppKit's live window arrays can shift when the selected tab changes,
    /// so we resolve them through a persisted surface-ID order first.
    private func orderedTabWindows(for window: NSWindow) -> [NSWindow] {
        let rawWindows = appKitTabWindows(for: window)
        let persistedOrder = syncManualTabOrder(with: rawWindows)
        guard !persistedOrder.isEmpty else { return rawWindows }

        let orderIndex = Dictionary(
            uniqueKeysWithValues: persistedOrder.enumerated().map { ($0.element, $0.offset) }
        )

        return rawWindows.enumerated().sorted { lhs, rhs in
            let lhsIndex = tabOrderKey(for: lhs.element).flatMap { orderIndex[$0] } ?? Int.max
            let rhsIndex = tabOrderKey(for: rhs.element).flatMap { orderIndex[$0] } ?? Int.max
            if lhsIndex != rhsIndex {
                return lhsIndex < rhsIndex
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Returns AppKit's current tab group windows without any sidebar-specific ordering.
    private func appKitTabWindows(for window: NSWindow) -> [NSWindow] {
        if let groupWindows = window.tabGroup?.windows, !groupWindows.isEmpty {
            return groupWindows
        }
        if let tabbedWindows = window.tabbedWindows, !tabbedWindows.isEmpty {
            return tabbedWindows
        }
        return [window]
    }

    private func setupObservers() {
        let center = NotificationCenter.default

        let keyObserver = center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let window = self.window,
                  let notifWindow = notification.object as? NSWindow,
                  self.orderedTabWindows(for: window).contains(notifWindow)
            else { return }
            self.refreshSelection()
        }
        observers.append(keyObserver)

        let resignObserver = center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let window = self.window,
                  let notifWindow = notification.object as? NSWindow,
                  self.orderedTabWindows(for: window).contains(notifWindow)
            else { return }
            self.refreshSelection()
        }
        observers.append(resignObserver)

        // Bell: respect bell-features config
        if bellTriggersAttention {
            let bellObserver = center.addObserver(
                forName: .terminalWindowBellDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let controller = notification.object as? BaseTerminalController,
                      let w = controller.window else { return }
                let hasBell = notification.userInfo?[Notification.Name.terminalWindowHasBellKey] as? Bool ?? false
                if hasBell {
                    self.markAttention(window: w)
                } else {
                    self.clearAttention(for: ObjectIdentifier(w))
                    self.refresh(reason: "bell cleared")
                }
            }
            observers.append(bellObserver)
        }

        // Desktop notifications (OSC 9/99, command completion): always trigger attention
        let desktopNotifObserver = center.addObserver(
            forName: .ghosttyDesktopNotificationDidFire,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let surfaceView = notification.object as? Ghostty.SurfaceView,
                  let w = surfaceView.window else { return }
            self.markAttention(window: w)
        }
        observers.append(desktopNotifObserver)

        // IPC notifications (tab.notify command): trigger attention
        let ipcNotifObserver = center.addObserver(
            forName: .ghosttyIPCNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let w = notification.object as? NSWindow else { return }
            self.markAttention(window: w)
        }
        observers.append(ipcNotifObserver)

        // Poll periodically for tab group changes, title changes, pwd changes, metadata changes.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refresh(reason: "timer")
        }
    }

    // MARK: - Attention

    private func markAttention(window w: NSWindow) {
        attentionWindows.insert(ObjectIdentifier(w))
        refresh(reason: "attention set")
    }

    private func clearAttention(for id: ObjectIdentifier) {
        guard attentionWindows.remove(id) != nil else { return }
        // Patch the cached tab model so the attention indicator clears immediately
        // without waiting for a full refresh().
        if let idx = tabs.firstIndex(where: { $0.id == id && $0.needsAttention }) {
            let old = tabs[idx]
            tabs[idx] = TabItem(
                id: old.id, title: old.title, pwd: old.pwd,
                gitDiffStats: old.gitDiffStats, surfaceId: old.surfaceId,
                statusEntries: old.statusEntries, needsAttention: false,
                hasUnreadCompletion: old.hasUnreadCompletion,
                tabColor: old.tabColor, faviconImage: old.faviconImage,
                window: old.window, projectRoot: old.projectRoot,
                lastActivity: old.lastActivity,
                createdAt: old.createdAt
            )
        }
    }

    /// Acknowledge the current completion token for a tab so its green dot stops pulsing.
    private func acknowledgeCompletion(for tab: TabItem) {
        guard let sid = tab.surfaceId else { return }
        let token = tab.statusEntries.first(where: { $0.key == "claude-done-at" || $0.key == "codex-done-at" })?.value
        guard let token else { return }
        acknowledgedDoneToken[sid] = token
    }

    // MARK: - Project Root Detection

    /// Project root marker files, in priority order.
    private static let projectRootMarkers = [
        ".git", "package.json", "Cargo.toml", "go.mod",
        "pyproject.toml", "Gemfile", "pom.xml", "build.gradle",
    ]

    /// Detect the project root for a given working directory by walking up the
    /// directory tree looking for project root markers. Results are cached.
    private func detectProjectRoot(at pwd: String) -> String? {
        if let cached = Self.projectRootCache[pwd] {
            return cached
        }

        let result = Self.findProjectRoot(at: pwd)
        Self.projectRootCache[pwd] = result
        return result
    }

    /// Walk up from `pwd` looking for a directory containing a project root marker.
    nonisolated private static func findProjectRoot(at pwd: String) -> String? {
        let fm = FileManager.default
        var dir = pwd
        while dir != "/" && dir.hasPrefix("/Users") {
            for marker in projectRootMarkers {
                let markerPath = (dir as NSString).appendingPathComponent(marker)
                if fm.fileExists(atPath: markerPath) {
                    return dir
                }
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    // MARK: - Project Grouping

    /// Tracks when each tab's observable state last changed, for "Last activity" sorting.
    /// Updated whenever title, pwd, or status entries change — NOT on tab selection.
    private var lastActivityTime: [ObjectIdentifier: Date] = [:]

    /// Previous state fingerprints per tab, used to detect real activity.
    private var previousTabFingerprints: [ObjectIdentifier: Int] = [:]

    /// Persisted manual ordering of project roots.
    private var manualProjectOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: "SidebarManualProjectOrder") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "SidebarManualProjectOrder") }
    }

    /// Persisted manual ordering of tabs by surface UUID string.
    private var manualTabOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: "SidebarManualTabOrder") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "SidebarManualTabOrder") }
    }

    /// Tracks when each tab was first seen (created), for "Created at" sorting.
    private var tabCreationTime: [ObjectIdentifier: Date] = [:]

    /// Tracks when each tab was first seen THIS SESSION (not persisted).
    /// Used to ignore fingerprint changes during tab initialization.
    private var tabFirstSeenTime: [ObjectIdentifier: Date] = [:]

    /// Last-known title per tab, for detecting command execution.
    /// Compared by string equality so re-emission of the same title
    /// (which happens on tab selection) is correctly ignored.
    private var previousTabTitles: [ObjectIdentifier: String] = [:]

    /// Surface UUID string used for persisted tab ordering.
    private func tabOrderKey(for window: NSWindow) -> String? {
        guard let controller = window.windowController as? BaseTerminalController,
              let surfaceId = controller.focusedSurface?.id else { return nil }
        return surfaceId.uuidString
    }

    /// All currently-live tab surface IDs across the app.
    private func allLiveTabOrderKeys() -> Set<String> {
        Set(NSApp.windows.compactMap { tabOrderKey(for: $0) })
    }

    /// Prune closed tabs, de-duplicate persisted entries, and append newly seen tabs.
    @discardableResult
    private func syncManualTabOrder(with windows: [NSWindow]) -> [String] {
        let liveGroupIds = windows.compactMap { tabOrderKey(for: $0) }
        let allLiveIds = allLiveTabOrderKeys()

        var changed = false
        var seen = Set<String>()
        var order: [String] = []

        for id in manualTabOrder where allLiveIds.contains(id) && seen.insert(id).inserted {
            order.append(id)
        }
        if order != manualTabOrder {
            changed = true
        }

        for id in liveGroupIds where seen.insert(id).inserted {
            order.append(id)
            changed = true
        }

        if changed {
            manualTabOrder = order
        }

        return order
    }

    /// Replace this tab group's slice of the persisted order after a drag reorder.
    private func persistTabOrder(_ reorderedGroupIds: [String], for windows: [NSWindow]) {
        guard !reorderedGroupIds.isEmpty else { return }

        var order = syncManualTabOrder(with: windows)
        let groupIdSet = Set(windows.compactMap { tabOrderKey(for: $0) })
        let insertionIndex = order.firstIndex(where: { groupIdSet.contains($0) }) ?? order.count

        order.removeAll { groupIdSet.contains($0) }
        order.insert(contentsOf: reorderedGroupIds, at: insertionIndex)
        manualTabOrder = order
    }

    /// Remove closed tabs from the persisted order immediately.
    private func removeTabsFromManualOrder(_ ids: [String]) {
        let idSet = Set(ids)
        guard !idSet.isEmpty else { return }
        let filtered = manualTabOrder.filter { !idSet.contains($0) }
        if filtered != manualTabOrder {
            manualTabOrder = filtered
        }
    }

    /// Timer fingerprint built from stable tab ordering and per-tab observable state.
    private func refreshFingerprint(for tabWindows: [NSWindow], metadataStore: TabMetadataStore) -> Int {
        var hasher = Hasher()
        hasher.combine(tabWindows.count)
        hasher.combine(attentionWindows.count)
        for window in tabWindows {
            hasher.combine(tabOrderKey(for: window) ?? "window-\(ObjectIdentifier(window).hashValue)")
            hasher.combine(window.title)
            if let ctrl = window.windowController as? BaseTerminalController,
               let surface = ctrl.focusedSurface {
                hasher.combine(surface.id)
                hasher.combine(surface.pwd)
                for entry in metadataStore.statusEntries(for: surface.id) {
                    hasher.combine(entry.key)
                    hasher.combine(entry.value)
                    hasher.combine(entry.icon)
                }
            }
        }
        return hasher.finalize()
    }

    /// Record creation time for a tab if not already tracked.
    /// Persists to TabMetadataStore so the timestamp survives app restarts.
    private func recordTabCreationTime(_ tabId: ObjectIdentifier, surfaceId: UUID?) {
        guard tabCreationTime[tabId] == nil else { return }
        let store = TabMetadataStore.shared
        // Try to restore a persisted creation time first
        if let sid = surfaceId,
           let entry = store.entries[sid]?["tab-created-at"],
           let epoch = Double(entry.value) {
            tabCreationTime[tabId] = Date(timeIntervalSince1970: epoch)
        } else {
            let now = Date()
            tabCreationTime[tabId] = now
            // Persist so it survives restart
            if let sid = surfaceId {
                store.setStatus(tabId: sid, key: "tab-created-at",
                    value: String(Int(now.timeIntervalSince1970)))
            }
        }
    }

    /// Reorder a project group from one index to another (for manual sort).
    func moveProjectGroup(fromId: String, toId: String) {
        var order = manualProjectOrder
        // Ensure all current groups are in the order list
        let currentIds = projectGroups.filter({ !$0.isOtherGroup }).map(\.id)
        for id in currentIds where !order.contains(id) {
            order.append(id)
        }
        guard let fromIdx = order.firstIndex(of: fromId),
              let toIdx = order.firstIndex(of: toId) else { return }
        let item = order.remove(at: fromIdx)
        order.insert(item, at: toIdx)
        manualProjectOrder = order
        projectGroups = buildProjectGroups(from: tabs)
    }

    /// Build project groups from the current tab list.
    private func buildProjectGroups(from tabs: [TabItem]) -> [ProjectGroup] {
        // Group tabs by project root, preserving tab order
        var projectTabs: [String: [TabItem]] = [:]
        var projectOrder: [String] = []  // stable insertion order
        var otherTabs: [TabItem] = []

        for tab in tabs {
            if let root = tab.projectRoot {
                if projectTabs[root] == nil {
                    projectOrder.append(root)
                }
                projectTabs[root, default: []].append(tab)
            } else {
                otherTabs.append(tab)
            }
        }

        var groups: [ProjectGroup] = []

        // Build groups in stable insertion order (avoids Dictionary random iteration)
        for root in projectOrder {
            guard var rootTabs = projectTabs[root] else { continue }

            // Sort tabs within the group based on the selected sort mode.
            switch projectSortMode {
            case .createdAt:
                // Stable creation order — oldest tab first (top)
                rootTabs.sort { a, b in
                    let aTime = tabCreationTime[a.id] ?? .distantPast
                    let bTime = tabCreationTime[b.id] ?? .distantPast
                    return aTime < bTime
                }
            case .lastActivity:
                // Most recently active tab on top
                rootTabs.sort { a, b in
                    let aTime = lastActivityTime[a.id] ?? .distantPast
                    let bTime = lastActivityTime[b.id] ?? .distantPast
                    return aTime > bTime
                }
            case .manual:
                // Preserve tab strip order — no sorting
                break
            }

            let name = (root as NSString).lastPathComponent
            let favicon = rootTabs.first?.faviconImage
            let stats = gitStatsWatcher.stats[root]

            groups.append(ProjectGroup(
                id: root,
                name: name,
                projectRoot: root,
                tabs: rootTabs,
                faviconImage: favicon,
                gitDiffStats: stats
            ))
        }

        // Sort groups based on selected sort mode
        switch projectSortMode {
        case .lastActivity:
            groups.sort { a, b in
                let aTime = a.tabs.compactMap({ lastActivityTime[$0.id] }).max() ?? .distantPast
                let bTime = b.tabs.compactMap({ lastActivityTime[$0.id] }).max() ?? .distantPast
                return aTime > bTime
            }
        case .createdAt:
            // Sort by earliest tab creation time per project (oldest project first).
            // This produces a stable order — creating a new tab in an existing
            // project does NOT change the project's position.
            groups.sort { a, b in
                let aTime = a.tabs.compactMap({ tabCreationTime[$0.id] }).min() ?? .distantPast
                let bTime = b.tabs.compactMap({ tabCreationTime[$0.id] }).min() ?? .distantPast
                return aTime < bTime
            }
        case .manual:
            // Ensure all current groups are in the persisted order
            var order = manualProjectOrder
            let currentIds = Set(groups.map(\.id))
            var changed = false
            for id in groups.map(\.id) where !order.contains(id) {
                order.append(id)
                changed = true
            }
            // Remove stale entries
            order = order.filter { currentIds.contains($0) }
            if changed { manualProjectOrder = order }

            groups.sort { a, b in
                let aIdx = order.firstIndex(of: a.id) ?? Int.max
                let bIdx = order.firstIndex(of: b.id) ?? Int.max
                return aIdx < bIdx
            }
        }

        // Add "Other" group at the end always
        if !otherTabs.isEmpty {
            // Sort tabs in "Other" group using the same mode as project groups
            switch projectSortMode {
            case .createdAt:
                otherTabs.sort { a, b in
                    let aTime = tabCreationTime[a.id] ?? .distantPast
                    let bTime = tabCreationTime[b.id] ?? .distantPast
                    return aTime < bTime
                }
            case .lastActivity:
                otherTabs.sort { a, b in
                    let aTime = lastActivityTime[a.id] ?? .distantPast
                    let bTime = lastActivityTime[b.id] ?? .distantPast
                    return aTime > bTime
                }
            case .manual:
                break
            }
            groups.append(ProjectGroup(
                id: "__other__",
                name: "Other",
                projectRoot: nil,
                tabs: otherTabs,
                faviconImage: nil,
                gitDiffStats: nil
            ))
        }

        return groups
    }

    // MARK: - Favicon Detection

    /// Search order for favicon files, based on common web framework conventions.
    private static let faviconSearchDirs = [
        "public",
        "app",
        "src/app",
        "src/assets",
        "assets",
        "static",
        "frontend/public",
        "",  // project root
    ]

    /// Extensions to try, in priority order (SVG > PNG > ICO > WEBP).
    private static let faviconExtensions = ["svg", "png", "ico", "webp"]

    /// Detect a favicon image for the project at the given pwd.
    /// Walks up to find a project root (package.json or .git), then searches
    /// known locations for favicon files. Results are cached by pwd.
    /// On cache miss, detection runs on a background queue and triggers a
    /// refresh when complete — returns nil immediately so the main thread
    /// is never blocked by filesystem scans.
    private func detectFavicon(at pwd: String) -> NSImage? {
        // Return cached result if available
        if let cached = Self.faviconCache[pwd] {
            return cached
        }

        // Start background detection if not already in progress
        if !Self.faviconDetectionInFlight.contains(pwd) {
            Self.faviconDetectionInFlight.insert(pwd)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let fm = FileManager.default
                let result = SidebarTabManager.findFaviconInBackground(at: pwd, using: fm)
                DispatchQueue.main.async {
                    Self.faviconDetectionInFlight.remove(pwd)
                    Self.faviconCache[pwd] = result
                    self?.refresh(reason: "favicon detected")
                }
            }
        }
        return nil
    }

    /// Fallback icon filenames when no favicon.* is found.
    private static let fallbackIconNames = [
        "icon-32x32.png", "icon-48x48.png", "icon-192x192.png",
        "apple-touch-icon.png", "logo.svg", "logo.png",
    ]

    /// Background-safe favicon search. Static so it can be called from a
    /// background queue without capturing `self`.
    nonisolated private static func findFaviconInBackground(at pwd: String, using fm: FileManager) -> NSImage? {
        var dir = pwd
        while dir != "/" && dir.hasPrefix("/Users") {
            let isProjectRoot = fm.fileExists(atPath: (dir as NSString).appendingPathComponent("package.json"))
                || fm.fileExists(atPath: (dir as NSString).appendingPathComponent(".git"))
                || fm.fileExists(atPath: (dir as NSString).appendingPathComponent("Cargo.toml"))
                || fm.fileExists(atPath: (dir as NSString).appendingPathComponent("go.mod"))

            if isProjectRoot {
                for searchDir in faviconSearchDirs {
                    let base = searchDir.isEmpty ? dir : (dir as NSString).appendingPathComponent(searchDir)
                    // Try standard favicon.{ext}
                    for ext in faviconExtensions {
                        let path = (base as NSString).appendingPathComponent("favicon.\(ext)")
                        if let image = loadFaviconFromDisk(at: path) { return image }
                    }
                    // Try sized variants and fallback names
                    let sized = (base as NSString).appendingPathComponent("favicon-32x32.png")
                    if let image = loadFaviconFromDisk(at: sized) { return image }

                    for name in fallbackIconNames {
                        let path = (base as NSString).appendingPathComponent(name)
                        if let image = loadFaviconFromDisk(at: path) { return image }
                    }
                }

                // Try app icons (iOS/macOS/Android)
                if let image = findAppIcon(in: dir, using: fm) { return image }

                // Try extracting favicon from HTML files
                if let image = extractFaviconFromHTML(in: dir, using: fm) { return image }

                return nil  // Found project root but no favicon
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    nonisolated private static func loadFaviconFromDisk(at path: String) -> NSImage? {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    // MARK: - App Icon Detection (iOS/macOS/Android)

    /// xcassets directory names used by Xcode projects.
    private static let xcassetsNames = ["Assets.xcassets", "Images.xcassets"]

    /// App icon asset set directory names.
    private static let appIconSetNames = ["AppIcon.appiconset", "AppIconImage.imageset"]

    /// Known subdirectories where xcassets may live, relative to project root.
    private static let xcassetsSearchPaths = [
        "",              // project root (e.g. macOS apps like Ghostty)
        "ios/Runner",    // Flutter iOS
        "macos/Runner",  // Flutter macOS
        "ios",           // React Native (subdirs also checked)
        "macos",
    ]

    /// Android mipmap density directories in preferred order for small display.
    private static let androidMipmapDensities = [
        "mipmap-xhdpi", "mipmap-hdpi", "mipmap-xxhdpi",
        "mipmap-mdpi", "mipmap-xxxhdpi",
    ]

    /// Android res directory search paths.
    private static let androidResSearchPaths = [
        "app/src/main/res",
        "android/app/src/main/res",
    ]

    /// Minimal Decodable for Xcode asset catalog Contents.json.
    private struct AssetContents: Decodable {
        let images: [AssetImage]?
        struct AssetImage: Decodable {
            let filename: String?
            let size: String?
            let scale: String?
        }
    }

    /// Try iOS/macOS app icon first, then Android.
    nonisolated private static func findAppIcon(in projectRoot: String, using fm: FileManager) -> NSImage? {
        if let image = findXcodeAppIcon(in: projectRoot, using: fm) { return image }
        if let image = findAndroidAppIcon(in: projectRoot, using: fm) { return image }
        return nil
    }

    /// Search for an Xcode app icon by looking for xcassets directories in
    /// known locations and the project root's immediate subdirectories.
    nonisolated private static func findXcodeAppIcon(in projectRoot: String, using fm: FileManager) -> NSImage? {
        var dirsToCheck: [String] = []

        for searchPath in xcassetsSearchPaths {
            let base = searchPath.isEmpty ? projectRoot : (projectRoot as NSString).appendingPathComponent(searchPath)
            dirsToCheck.append(base)

            // For "ios"/"macos" paths, also check their immediate subdirectories
            // (React Native puts xcassets in ios/{ProjectName}/)
            if searchPath == "ios" || searchPath == "macos" {
                if let subdirs = try? fm.contentsOfDirectory(atPath: base) {
                    for subdir in subdirs where !subdir.hasPrefix(".") {
                        let fullPath = (base as NSString).appendingPathComponent(subdir)
                        var isDir: ObjCBool = false
                        if fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                            dirsToCheck.append(fullPath)
                        }
                    }
                }
            }
        }

        // Also check immediate subdirectories of project root — native Xcode
        // projects often have source in a directory named after the project.
        if let rootContents = try? fm.contentsOfDirectory(atPath: projectRoot) {
            for item in rootContents where !item.hasPrefix(".") {
                let fullPath = (projectRoot as NSString).appendingPathComponent(item)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                    dirsToCheck.append(fullPath)
                }
            }
        }

        for dir in dirsToCheck {
            for xcassetsName in xcassetsNames {
                let xcassetsPath = (dir as NSString).appendingPathComponent(xcassetsName)
                guard fm.fileExists(atPath: xcassetsPath) else { continue }

                for iconSetName in appIconSetNames {
                    let iconSetPath = (xcassetsPath as NSString).appendingPathComponent(iconSetName)
                    guard fm.fileExists(atPath: iconSetPath) else { continue }

                    if let image = loadBestIconFromAssetSet(at: iconSetPath, using: fm) {
                        return image
                    }
                }
            }
        }
        return nil
    }

    /// Load the best-sized icon from an Xcode asset set by parsing Contents.json.
    /// Prefers icons around 60–120px to avoid loading the 1024px marketing icon.
    nonisolated private static func loadBestIconFromAssetSet(at path: String, using fm: FileManager) -> NSImage? {
        let contentsPath = (path as NSString).appendingPathComponent("Contents.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: contentsPath)),
              let contents = try? JSONDecoder().decode(AssetContents.self, from: data),
              let images = contents.images else {
            // No Contents.json — try loading any image file directly
            return loadAnyImageFromDirectory(at: path, using: fm)
        }

        let candidates: [(String, Int)] = images.compactMap { img in
            guard let filename = img.filename else { return nil }
            let filePath = (path as NSString).appendingPathComponent(filename)
            guard fm.fileExists(atPath: filePath) else { return nil }
            let pixelSize = pixelSizeFromAsset(size: img.size, scale: img.scale)
            return (filePath, pixelSize)
        }

        // Sort by closeness to 90px — a good middle ground for downscaling to 12px
        let sorted = candidates.sorted { abs($0.1 - 90) < abs($1.1 - 90) }
        for (filePath, _) in sorted {
            if let image = loadFaviconFromDisk(at: filePath) { return image }
        }

        return nil
    }

    /// Calculate pixel size from Contents.json size/scale strings.
    nonisolated private static func pixelSizeFromAsset(size: String?, scale: String?) -> Int {
        guard let size = size,
              let pointSize = Double(size.split(separator: "x").first ?? "") else { return 0 }
        let scaleVal = Double(scale?.replacingOccurrences(of: "x", with: "") ?? "1") ?? 1.0
        return Int(pointSize * scaleVal)
    }

    /// Fallback: load any image file from a directory.
    nonisolated private static func loadAnyImageFromDirectory(at path: String, using fm: FileManager) -> NSImage? {
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return nil }
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]
        for filename in contents {
            let ext = (filename as NSString).pathExtension.lowercased()
            if imageExtensions.contains(ext) {
                let filePath = (path as NSString).appendingPathComponent(filename)
                if let image = loadFaviconFromDisk(at: filePath) { return image }
            }
        }
        return nil
    }

    /// Search Android mipmap directories for launcher icons.
    nonisolated private static func findAndroidAppIcon(in projectRoot: String, using fm: FileManager) -> NSImage? {
        let iconNames = ["ic_launcher.png", "ic_launcher.webp",
                         "ic_launcher_round.png", "ic_launcher_round.webp"]

        for resPath in androidResSearchPaths {
            let resDir = (projectRoot as NSString).appendingPathComponent(resPath)
            guard fm.fileExists(atPath: resDir) else { continue }

            for density in androidMipmapDensities {
                let mipmapDir = (resDir as NSString).appendingPathComponent(density)
                for iconName in iconNames {
                    let iconPath = (mipmapDir as NSString).appendingPathComponent(iconName)
                    if let image = loadFaviconFromDisk(at: iconPath) { return image }
                }
            }
        }
        return nil
    }

    // MARK: - HTML Favicon Extraction

    /// HTML files to check for embedded favicon references, in priority order.
    private static let htmlFileNames = ["index.html", "index.htm"]

    /// Search HTML files for `<link rel="icon" href="...">` and resolve the
    /// href — either as a file path relative to the project root, or as an
    /// inline data URI (SVG or base64-encoded image).
    nonisolated private static func extractFaviconFromHTML(in projectRoot: String, using fm: FileManager) -> NSImage? {
        for name in htmlFileNames {
            // Look for the HTML file in the same dirs we search for favicon files
            for searchDir in faviconSearchDirs {
                let base = searchDir.isEmpty ? projectRoot : (projectRoot as NSString).appendingPathComponent(searchDir)
                let htmlPath = (base as NSString).appendingPathComponent(name)
                guard fm.fileExists(atPath: htmlPath),
                      let contents = try? String(contentsOfFile: htmlPath, encoding: .utf8) else { continue }

                if let image = parseFaviconFromHTML(contents, projectRoot: projectRoot, htmlDir: base, using: fm) {
                    return image
                }
            }
        }
        return nil
    }

    /// Parse HTML content for a `<link>` tag with rel containing "icon" and
    /// extract the href value.
    nonisolated private static func parseFaviconFromHTML(_ html: String, projectRoot: String, htmlDir: String, using fm: FileManager) -> NSImage? {
        // Match <link> tags that may contain quoted attributes with > or mixed
        // quotes inside (common with inline SVG data URIs). The alternation
        // handles: bare chars, double-quoted strings, and single-quoted strings.
        let tagPattern = #"<link\s(?:[^>"']|"[^"]*"|'[^']*')*>"#
        guard let tagRegex = try? NSRegularExpression(pattern: tagPattern, options: .caseInsensitive) else { return nil }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let tagMatches = tagRegex.matches(in: html, range: range)

        for tagMatch in tagMatches {
            guard let tagRange = Range(tagMatch.range, in: html) else { continue }
            let tag = String(html[tagRange])

            // Only consider tags where rel includes "icon"
            let relPattern = #"rel\s*=\s*["'](?:shortcut\s+)?icon["']"#
            guard let relRegex = try? NSRegularExpression(pattern: relPattern, options: .caseInsensitive),
                  relRegex.firstMatch(in: tag, range: NSRange(tag.startIndex..<tag.endIndex, in: tag)) != nil else { continue }

            // Extract href — try double-quoted then single-quoted to respect
            // the actual delimiter (data URIs often contain the other quote type).
            let href: String?
            if let val = extractAttributeValue(from: tag, attribute: "href", quote: "\"") {
                href = val
            } else if let val = extractAttributeValue(from: tag, attribute: "href", quote: "'") {
                href = val
            } else {
                continue
            }
            guard let href else { continue }

            // Handle data URIs
            if href.hasPrefix("data:") {
                if let image = loadFaviconFromDataURI(href) { return image }
                continue
            }

            // Handle file path references — resolve relative to project root
            let resolvedPath: String
            if href.hasPrefix("/") {
                // Absolute path from project root
                resolvedPath = (projectRoot as NSString).appendingPathComponent(String(href.dropFirst()))
            } else {
                // Relative to the HTML file's directory
                resolvedPath = (htmlDir as NSString).appendingPathComponent(href)
            }
            if let image = loadFaviconFromDisk(at: resolvedPath) { return image }
        }
        return nil
    }

    /// Extract an attribute value from an HTML tag using the specified quote
    /// delimiter. This avoids regex issues with data URIs that contain mixed
    /// quote types and angle brackets.
    nonisolated private static func extractAttributeValue(from tag: String, attribute: String, quote: Character) -> String? {
        // Find the attribute name followed by = and the opening quote
        let search = "\(attribute)="
        guard let attrStart = tag.range(of: search, options: .caseInsensitive) else { return nil }
        let afterEquals = tag[attrStart.upperBound...]
        // Skip optional whitespace
        let trimmed = afterEquals.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmed.first == quote else { return nil }
        let valueStart = trimmed.index(after: trimmed.startIndex)
        guard let valueEnd = trimmed[valueStart...].firstIndex(of: quote) else { return nil }
        return String(trimmed[valueStart..<valueEnd])
    }

    /// Decode a `data:` URI into an NSImage. Supports:
    /// - `data:image/svg+xml,...` (URL-encoded SVG)
    /// - `data:image/svg+xml;base64,...`
    /// - `data:image/png;base64,...` (and other image types)
    nonisolated private static func loadFaviconFromDataURI(_ uri: String) -> NSImage? {
        // Split into metadata and payload at the first comma
        guard let commaIndex = uri.firstIndex(of: ",") else { return nil }
        let metadata = String(uri[uri.startIndex..<commaIndex]).lowercased()
        let payload = String(uri[uri.index(after: commaIndex)...])

        guard metadata.hasPrefix("data:image/") else { return nil }

        let imageData: Data?
        if metadata.contains(";base64") {
            imageData = Data(base64Encoded: payload)
        } else {
            // URL-encoded content (common for inline SVG)
            guard let decoded = payload.removingPercentEncoding else { return nil }
            imageData = decoded.data(using: .utf8)
        }

        guard let data = imageData, let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    // MARK: - Selection

    /// Lightweight update that only syncs `selectedTabID` from the window's tab group,
    /// without rebuilding the full tab list.
    private func refreshSelection() {
        guard !isSelectingTab else { return }
        guard let window else { return }
        let selectedWindow = window.tabGroup?.selectedWindow ?? window
        let newID = ObjectIdentifier(selectedWindow)
        if selectedTabID != newID {
            selectedTabID = newID
        }
    }

    // MARK: - Refresh

    func refresh() {
        refresh(reason: "manual")
    }

    private func refresh(reason: String) {
        guard let window else { return }

        // Keep collapsed state in sync across all tab managers
        syncCollapsedProjects()

        let tabWindows = orderedTabWindows(for: window)

        let selectedWindow = window.tabGroup?.selectedWindow ?? window
        let metadataStore = TabMetadataStore.shared

        // For timer-driven refreshes, skip if nothing observable has changed.
        // Git stats are refreshed independently of the fingerprint (they run on
        // their own interval), so we check them before the early return.
        let timerFingerprint: Int?
        if reason == "timer" {
            timerFingerprint = refreshFingerprint(for: tabWindows, metadataStore: metadataStore)
        } else {
            timerFingerprint = nil
        }

        var faviconCacheMisses = 0

        let newTabs = tabWindows.map { w -> TabItem in
            let controller = w.windowController as? BaseTerminalController
            let surface = controller?.focusedSurface
            let wid = ObjectIdentifier(w)
            let sid = surface?.id
            let pwd = surface?.pwd
            let entries = sid.map { metadataStore.statusEntries(for: $0) } ?? []
            let projectRoot = pwd.flatMap { detectProjectRoot(at: $0) }
            // Look up git stats by project root (from FSEvents watcher)
            let diffStats = projectRoot.flatMap { gitStatsWatcher.stats[$0] }
            let favicon = pwd.flatMap { pwd -> NSImage? in
                if Self.faviconCache.index(forKey: pwd) == nil {
                    faviconCacheMisses += 1
                }
                return detectFavicon(at: pwd)
            }
            let color = (w as? TerminalWindow)?.tabColor ?? .none

            // Determine whether this tab has an unread completion.
            let doneToken = entries.first(where: { $0.key == "claude-done-at" || $0.key == "codex-done-at" })?.value
            let isCurrentTab = wid == selectedTabID
            var unread = false
            if let sid, let token = doneToken {
                if isCurrentTab {
                    // Auto-ack: tab is frontmost, so mark as read immediately
                    acknowledgedDoneToken[sid] = token
                } else {
                    unread = acknowledgedDoneToken[sid] != token
                }
            }

            return TabItem(
                id: wid,
                title: w.title,
                pwd: pwd,
                gitDiffStats: diffStats,
                surfaceId: sid,
                statusEntries: entries,
                needsAttention: attentionWindows.contains(wid),
                hasUnreadCompletion: unread,
                tabColor: color,
                faviconImage: favicon,
                window: w,
                projectRoot: projectRoot,
                lastActivity: lastActivityTime[wid],
                createdAt: tabCreationTime[wid]
            )
        }

        // Detect real activity by comparing per-tab fingerprints (pwd +
        // status entries) and title changes. Title is tracked separately via
        // string equality (not hashed) so that re-emission of the same title
        // on tab selection is correctly ignored — only actual value changes
        // (e.g. a new command running) count as activity.
        let now = Date()
        for tab in newTabs {
            var hasher = Hasher()
            hasher.combine(tab.pwd)
            for entry in tab.statusEntries where entry.key != "last-activity" {
                hasher.combine(entry.key)
                hasher.combine(entry.value)
            }
            let fp = hasher.finalize()
            if let prev = previousTabFingerprints[tab.id] {
                // Skip fingerprint changes that aren't real user activity:
                // 1. First 5 seconds after a tab appears (shell initialization)
                // 2. Session resuming: claude-pid/codex-pid is set (SessionStart
                //    hook fired) but claude-active/codex-active hasn't appeared
                //    yet (user hasn't submitted a prompt). This covers pressing
                //    Enter on the pre-filled resume command without counting it
                //    as activity. If the user deletes the command and runs
                //    something else, no pid is set so activity is tracked normally.
                let firstSeen = tabFirstSeenTime[tab.id] ?? .distantPast
                let isShellInit = now.timeIntervalSince(firstSeen) < 5.0
                let isSessionResuming: Bool = {
                    let hasPid = tab.statusEntries.contains(where: {
                        $0.key == "claude-pid" || $0.key == "codex-pid"
                    })
                    let hasActive = tab.statusEntries.contains(where: {
                        $0.key == "claude-active" || $0.key == "codex-active"
                    })
                    return hasPid && !hasActive
                }()

                // Detect activity from title changes separately.
                // Title is compared by string equality (not hashed) so that
                // re-emission of the same title on tab selection is ignored.
                // Running a command changes the title to the command name,
                // which is a genuine activity signal.
                let titleChanged = previousTabTitles[tab.id] != tab.title

                if (prev != fp || titleChanged) && !isShellInit && !isSessionResuming {
                    lastActivityTime[tab.id] = now
                    // Persist to disk so it survives restart
                    if let sid = tab.surfaceId {
                        metadataStore.setStatus(tabId: sid, key: "last-activity",
                            value: String(Int(now.timeIntervalSince1970)))

                        // If the tab changed and no coding agent is active or
                        // resuming, the user moved on from the session. Clear the
                        // session association so the tab reverts to its natural name.
                        // We must also check for session keys because there is a
                        // timing gap between sending the resume command and the
                        // hook setting the active marker.
                        let hasActiveAgent = tab.statusEntries.contains(where: {
                            $0.key == "claude-active" || $0.key == "codex-active"
                        })
                        let hasSessionInProgress = metadataStore.entries[sid]?["claude-session"] != nil ||
                            metadataStore.entries[sid]?["codex-session"] != nil
                        if !hasActiveAgent && !hasSessionInProgress && metadataStore.entries[sid]?["session-title"] != nil {
                            metadataStore.clearStatus(tabId: sid, key: "session-title")
                        }
                    }
                }
            }
            // First time seeing a tab: load persisted activity time or use creation order
            if previousTabFingerprints[tab.id] == nil {
                tabFirstSeenTime[tab.id] = now
                recordTabCreationTime(tab.id, surfaceId: tab.surfaceId)
                if let sid = tab.surfaceId,
                   let entry = metadataStore.entries[sid]?["last-activity"],
                   let epoch = Double(entry.value) {
                    lastActivityTime[tab.id] = Date(timeIntervalSince1970: epoch)
                } else {
                    // No persisted activity time — use creation time so
                    // restored tabs show their real age, not "now".
                    lastActivityTime[tab.id] = tabCreationTime[tab.id]
                }
            }
            previousTabFingerprints[tab.id] = fp
            previousTabTitles[tab.id] = tab.title
        }

        // Clean up in-memory timestamps for closed tabs
        let currentTabIds = Set(newTabs.map(\.id))
        lastActivityTime = lastActivityTime.filter { currentTabIds.contains($0.key) }
        tabCreationTime = tabCreationTime.filter { currentTabIds.contains($0.key) }
        tabFirstSeenTime = tabFirstSeenTime.filter { currentTabIds.contains($0.key) }
        previousTabFingerprints = previousTabFingerprints.filter { currentTabIds.contains($0.key) }
        previousTabTitles = previousTabTitles.filter { currentTabIds.contains($0.key) }

        // Sweep stale Claude sessions (every 30s) — detects crashed Claude processes
        if Date().timeIntervalSince(lastPidSweepTime) >= Self.pidSweepInterval {
            lastPidSweepTime = Date()
            metadataStore.sweepStaleClaude()
        }

        // Now apply the fingerprint gate: if nothing observable changed on a
        // timer tick, skip the (relatively expensive) tabs/groups rebuild.
        if let fp = timerFingerprint, fp == lastRefreshFingerprint {
            return
        }
        if let fp = timerFingerprint {
            lastRefreshFingerprint = fp
        }

        let tabsChanged = newTabs != tabs
        if tabsChanged {
            tabs = newTabs
            // Rebuild project groups whenever tabs change
            projectGroups = buildProjectGroups(from: newTabs)
        }

        // Sync the FSEvents git watcher with current project roots.
        let activeRoots = Set(newTabs.compactMap(\.projectRoot))
        gitStatsWatcher.sync(projectRoots: activeRoots)

        let currentSelectedID = ObjectIdentifier(selectedWindow)
        if selectedTabID != currentSelectedID {
            selectedTabID = currentSelectedID
        }
    }

    // MARK: - Sorting

    enum SortMode: String, CaseIterable {
        case manual = "Manual"
        case createdAt = "Created at"
        case lastActivity = "Last activity"
    }

    @Published var projectSortMode: SortMode = .manual

    func setProjectSortMode(_ mode: SortMode) {
        projectSortMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "SidebarProjectSort")
        // Rebuild groups with new sort order
        projectGroups = buildProjectGroups(from: tabs)
    }

    // MARK: - Tool Launch

    /// The CLI tools that can be auto-launched in a new tab.
    enum SidebarTool: String, CaseIterable {
        case terminal = "Terminal"
        case claudeCode = "Claude Code"
        case codex = "Codex"

        var icon: String {
            switch self {
            case .terminal: return "terminal"
            case .claudeCode: return "ClaudeIcon"
            case .codex: return "CodexIcon"
            }
        }

        var isCustomIcon: Bool {
            switch self {
            case .terminal: return false
            case .claudeCode, .codex: return true
            }
        }

        /// The shell command to launch this tool.
        var launchCommand: String? {
            switch self {
            case .terminal: return nil
            case .claudeCode: return "claude --dangerously-skip-permissions"
            case .codex: return "codex --dangerously-bypass-approvals-and-sandbox"
            }
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

    // MARK: - Git Actions

    /// Whether a git action (commit/push) is currently in progress for a project.
    @Published private var gitActionInProgress: Set<String> = []

    /// Run git commit with an AI-generated commit message for a project.
    func gitCommit(projectRoot: String) {
        guard !gitActionInProgress.contains(projectRoot) else { return }
        gitActionInProgress.insert(projectRoot)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.performGitCommit(at: projectRoot)
            DispatchQueue.main.async {
                self?.gitActionInProgress.remove(projectRoot)
                self?.gitStatsWatcher.refreshAll()
                Self.showGitNotification(result: result, action: "Commit")
            }
        }
    }

    /// Push the current branch to remote for a project.
    func gitPush(projectRoot: String) {
        guard !gitActionInProgress.contains(projectRoot) else { return }
        gitActionInProgress.insert(projectRoot)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.performGitPush(at: projectRoot)
            DispatchQueue.main.async {
                self?.gitActionInProgress.remove(projectRoot)
                Self.showGitNotification(result: result, action: "Push")
            }
        }
    }

    /// Commit all changes and push in one action.
    func gitCommitAndPush(projectRoot: String) {
        guard !gitActionInProgress.contains(projectRoot) else { return }
        gitActionInProgress.insert(projectRoot)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let commitResult = Self.performGitCommit(at: projectRoot)
            guard case .success = commitResult else {
                DispatchQueue.main.async {
                    self?.gitActionInProgress.remove(projectRoot)
                    self?.gitStatsWatcher.refreshAll()
                    Self.showGitNotification(result: commitResult, action: "Commit")
                }
                return
            }
            let pushResult = Self.performGitPush(at: projectRoot)
            DispatchQueue.main.async {
                self?.gitActionInProgress.remove(projectRoot)
                self?.gitStatsWatcher.refreshAll()
                if case .success = pushResult {
                    Self.showGitNotification(result: .success("Committed and pushed"), action: "Commit & Push")
                } else {
                    // Commit succeeded but push failed
                    Self.showGitNotification(result: pushResult, action: "Push")
                }
            }
        }
    }

    /// Check whether a git action is in progress for a project root.
    func isGitActionInProgress(forProjectRoot root: String?) -> Bool {
        guard let root else { return false }
        return gitActionInProgress.contains(root)
    }

    private enum GitActionResult {
        case success(String)
        case error(String)
    }

    /// Stage all changes, generate a commit message, and commit. Runs on background thread.
    nonisolated private static func performGitCommit(at projectRoot: String) -> GitActionResult {
        // Stage all changes
        guard runGit(["add", "-A"], at: projectRoot) else {
            return .error("Failed to stage changes")
        }

        // Check if there's anything staged
        let diffCheck = runGitOutput(["diff", "--cached", "--quiet"], at: projectRoot)
        if diffCheck.status == 0 {
            return .error("No changes to commit")
        }

        // Generate commit message via LLM
        let message = generateCommitMessage(at: projectRoot)
        guard let message, !message.isEmpty else {
            // Unstage so we don't leave things in a weird state
            _ = runGit(["reset", "HEAD"], at: projectRoot)
            return .error("Failed to generate commit message")
        }

        guard runGit(["commit", "-m", message], at: projectRoot) else {
            return .error("Failed to commit")
        }
        return .success(message)
    }

    /// Push the current branch to its remote. Runs on background thread.
    nonisolated private static func performGitPush(at projectRoot: String) -> GitActionResult {
        let result = runGitOutput(["push"], at: projectRoot)
        if result.status == 0 {
            return .success("Pushed successfully")
        } else {
            let errMsg = result.output.isEmpty ? "Push failed" : result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .error(errMsg)
        }
    }

    /// Generate a commit message by calling `claude -p` with the staged diff.
    /// Uses the same approach as ghostty-generate-title.sh — fast Haiku model, no project context.
    nonisolated private static func generateCommitMessage(at projectRoot: String) -> String? {
        // Get staged diff (truncated to keep request small)
        let diffResult = runGitOutput(["diff", "--cached"], at: projectRoot)
        guard diffResult.status == 0, !diffResult.output.isEmpty else { return nil }
        let diff = String(diffResult.output.prefix(8000))

        // Get changed file names for context
        let filesResult = runGitOutput(["diff", "--cached", "--name-only"], at: projectRoot)
        let files = filesResult.output.trimmingCharacters(in: .whitespacesAndNewlines)

        let prompt = """
        Return ONLY a JSON object {"message":"..."} with a good git commit message. \
        Use lowercase, imperative mood. If you can identify the subsystem from \
        file paths, prefix the subject with it (e.g. 'macos: fix tab rendering'). \
        Include a body after a blank line if the changes warrant explanation. \
        Files changed: \(files)\n\nDiff:\n\(diff)
        """

        // Run claude -p from /tmp to avoid loading project context
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "claude", "-p",
            "--no-session-persistence",
            "--output-format", "json",
            "--model", "claude-haiku-4-5",
            "--dangerously-skip-permissions",
            prompt,
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: "/tmp")

        // Don't let this process touch the sidebar
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "GHOSTTY_TAB_ID")
        env.removeValue(forKey: "GHOSTTY_SOCKET")
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return nil }

        // 30-second timeout for LLM call
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        if done.wait(timeout: .now() + .seconds(30)) == .timedOut {
            process.terminate()
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let responseStr = String(data: data, encoding: .utf8),
              !responseStr.isEmpty else { return nil }

        // Parse JSON response: first try { result: { message: "..." } } then { message: "..." }
        guard let responseData = responseStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else { return nil }

        var message: String?

        // Try nested: { result: "{ \"message\": ... }" } (claude -p --output-format json wraps in result)
        if let inner = json["result"] as? String {
            if let innerData = inner.data(using: .utf8),
               let innerJson = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any] {
                message = innerJson["message"] as? String
            }
            // Try stripping markdown code fences
            if message == nil {
                let stripped = inner
                    .replacingOccurrences(of: "```json", with: "")
                    .replacingOccurrences(of: "```", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let d = stripped.data(using: .utf8),
                   let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    message = j["message"] as? String
                }
            }
        }

        // Direct top-level
        if message == nil {
            message = json["message"] as? String
        }

        guard var msg = message, !msg.isEmpty else { return nil }

        // Sanitize: strip outer quotes
        if msg.hasPrefix("\"") { msg = String(msg.dropFirst()) }
        if msg.hasSuffix("\"") { msg = String(msg.dropLast()) }
        msg = msg.trimmingCharacters(in: .whitespacesAndNewlines)

        return msg.isEmpty ? nil : msg
    }

    /// Run a git command and return success/failure.
    nonisolated private static func runGit(_ args: [String], at dir: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Run a command and return its output + exit status.
    nonisolated private static func runGitOutput(
        _ args: [String], at dir: String, executable: String = "/usr/bin/git"
    ) -> (output: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        guard (try? process.run()) != nil else { return ("", 1) }
        process.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outData, encoding: .utf8) ?? ""
        let errOutput = String(data: errData, encoding: .utf8) ?? ""
        return (output.isEmpty ? errOutput : output, process.terminationStatus)
    }

    /// Show a macOS notification for git action results.
    private static func showGitNotification(result: GitActionResult, action: String) {
        let content = UNMutableNotificationContent()
        switch result {
        case .success(let message):
            content.title = "\(action) Succeeded"
            content.body = message
        case .error(let message):
            content.title = "\(action) Failed"
            content.body = message
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    // MARK: - Tab Actions

    func createNewTab() {
        NSApp.sendAction(#selector(TerminalController.newTab(_:)), to: nil, from: nil)
    }

    func selectTab(_ tab: TabItem) {
        // Only remove from the set — don't patch the @Published tabs array.
        // The source sidebar is about to become invisible anyway, and the next
        // timer-driven refresh() will rebuild tabs with needsAttention=false.
        attentionWindows.remove(tab.id)
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

    func setTabColor(_ color: TerminalTabColor, for tab: TabItem) {
        (tab.window as? TerminalWindow)?.tabColor = color
        refresh()
    }

    func closeTab(_ tab: TabItem) {
        guard let controller = tab.window.windowController as? TerminalController else { return }
        if let surfaceId = tab.surfaceId?.uuidString {
            removeTabsFromManualOrder([surfaceId])
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
        let tabWindows = orderedTabWindows(for: window)
        guard tabWindows.count > 1 else { return }
        let idsToRemove = tabWindows
            .filter { ObjectIdentifier($0) != tab.id }
            .compactMap { tabOrderKey(for: $0) }
        removeTabsFromManualOrder(idsToRemove)
        for w in tabWindows where ObjectIdentifier(w) != tab.id {
            if let controller = w.windowController as? TerminalController {
                controller.closeTab(nil)
            }
        }
    }

    func moveTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard let window else { return }
        let tabbedWindows = orderedTabWindows(for: window)
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < tabbedWindows.count,
              destinationIndex >= 0, destinationIndex < tabbedWindows.count else { return }

        let movingWindow = tabbedWindows[sourceIndex]
        let targetWindow = tabbedWindows[destinationIndex]

        let reorderedGroupIds: [String]? = {
            let ids = tabbedWindows.compactMap { tabOrderKey(for: $0) }
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
            persistTabOrder(reorderedGroupIds, for: tabbedWindows)
        }

        if let selectedWindow = window.tabGroup?.selectedWindow {
            selectedWindow.makeKeyAndOrderFront(nil)
        }

        refresh()
    }

    func closeTabsToTheRight(of tab: TabItem) {
        guard let window else { return }
        let tabWindows = orderedTabWindows(for: window)
        guard tabWindows.count > 1 else { return }
        guard let idx = tabWindows.firstIndex(where: { ObjectIdentifier($0) == tab.id }) else { return }
        let tabsToClose = Array(tabWindows[(idx + 1)...])
        removeTabsFromManualOrder(tabsToClose.compactMap { tabOrderKey(for: $0) })
        for w in tabsToClose {
            if let controller = w.windowController as? TerminalController {
                controller.closeTab(nil)
            }
        }
    }
}
