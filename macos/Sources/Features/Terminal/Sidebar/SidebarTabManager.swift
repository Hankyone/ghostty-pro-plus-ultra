import Cocoa
import Combine

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
        let tabColor: TerminalTabColor
        let faviconImage: NSImage?
        let window: NSWindow

        /// The last path component of the pwd, for compact display.
        var directoryName: String? {
            guard let pwd, !pwd.isEmpty else { return nil }
            return (pwd as NSString).lastPathComponent
        }

        /// Title with bell emoji stripped (the sidebar uses its own attention indicator).
        var displayTitle: String {
            title.hasPrefix("\u{1F514} ") ? String(title.dropFirst(3)) : title
        }

        static func == (lhs: TabItem, rhs: TabItem) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title
                && lhs.pwd == rhs.pwd && lhs.gitDiffStats == rhs.gitDiffStats
                && lhs.surfaceId == rhs.surfaceId
                && lhs.statusEntries == rhs.statusEntries
                && lhs.needsAttention == rhs.needsAttention
                && lhs.tabColor == rhs.tabColor
                && lhs.faviconImage === rhs.faviconImage
        }
    }

    @Published var tabs: [TabItem] = []
    @Published var selectedTabID: ObjectIdentifier?

    /// Windows that need attention, cleared when the tab is selected.
    private var attentionWindows: Set<ObjectIdentifier> = []

    /// Whether bells should trigger the sidebar attention indicator.
    /// Derived from `bell-features` containing `attention`.
    private let bellTriggersAttention: Bool

    /// Cache of detected favicons keyed by pwd to avoid re-scanning every refresh.
    /// Static so all SidebarTabManager instances share it.
    private static var faviconCache: [String: NSImage?] = [:]

    /// Pwds currently being detected in the background, to avoid duplicate work.
    private static var faviconDetectionInFlight: Set<String> = []

    /// Cache for git diff stats to avoid spawning git every 0.5s.
    private var gitStatsCache: [String: String?] = [:]
    private var gitStatsCacheTime: Date = .distantPast
    private static let gitStatsCacheInterval: TimeInterval = 5.0

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
        setupObservers()
        refresh(reason: "init")
    }

    deinit {
        timer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
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
                  (window.tabbedWindows ?? [window]).contains(notifWindow)
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
                  (window.tabbedWindows ?? [window]).contains(notifWindow)
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
                tabColor: old.tabColor, faviconImage: old.faviconImage,
                window: old.window
            )
        }
    }

    // MARK: - Git Diff Stats

    /// Run `git diff --shortstat HEAD` and return a compact "+N -N" string,
    /// or nil if there are no uncommitted changes or the directory is not a git repo.
    private func gitDiffStats(at pwd: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["diff", "--shortstat", "HEAD"]
        process.currentDirectoryURL = URL(fileURLWithPath: pwd)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !output.isEmpty else { return nil }

        // Parse: " 3 files changed, 12 insertions(+), 5 deletions(-)"
        var insertions = 0
        var deletions = 0

        if let range = output.range(of: #"\d+ insertion"#, options: .regularExpression) {
            insertions = Int(output[range].split(separator: " ")[0]) ?? 0
        }
        if let range = output.range(of: #"\d+ deletion"#, options: .regularExpression) {
            deletions = Int(output[range].split(separator: " ")[0]) ?? 0
        }

        if insertions == 0 && deletions == 0 { return nil }
        return "+\(insertions) -\(deletions)"
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
        image.size = NSSize(width: 12, height: 12)
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

        let tabWindows: [NSWindow]
        if let tabbedWindows = window.tabbedWindows, !tabbedWindows.isEmpty {
            tabWindows = tabbedWindows
        } else {
            tabWindows = [window]
        }

        let selectedWindow = window.tabGroup?.selectedWindow ?? window
        let metadataStore = TabMetadataStore.shared

        // For timer-driven refreshes, skip if nothing observable has changed.
        if reason == "timer" {
            var hasher = Hasher()
            hasher.combine(tabWindows.count)
            hasher.combine(ObjectIdentifier(selectedWindow))
            hasher.combine(attentionWindows.count)
            for w in tabWindows {
                hasher.combine(ObjectIdentifier(w))
                hasher.combine(w.title)
                if let ctrl = w.windowController as? BaseTerminalController,
                   let surface = ctrl.focusedSurface {
                    hasher.combine(surface.pwd)
                    hasher.combine(surface.id)
                    for entry in metadataStore.statusEntries(for: surface.id) {
                        hasher.combine(entry.key)
                        hasher.combine(entry.value)
                        hasher.combine(entry.icon)
                    }
                }
            }
            let fingerprint = hasher.finalize()
            if fingerprint == lastRefreshFingerprint {
                return
            }
            lastRefreshFingerprint = fingerprint
        }

        // Collect pwds for background git refresh
        var tabPwds: [String] = []
        var faviconCacheMisses = 0

        let newTabs = tabWindows.map { w -> TabItem in
            let controller = w.windowController as? BaseTerminalController
            let surface = controller?.focusedSurface
            let wid = ObjectIdentifier(w)
            let sid = surface?.id
            let pwd = surface?.pwd
            let entries = sid.map { metadataStore.statusEntries(for: $0) } ?? []
            // Always use cached git stats (never block the main thread)
            let diffStats = pwd.flatMap { gitStatsCache[$0] ?? nil }
            let favicon = pwd.flatMap { pwd -> NSImage? in
                if Self.faviconCache.index(forKey: pwd) == nil {
                    faviconCacheMisses += 1
                }
                return detectFavicon(at: pwd)
            }
            let color = (w as? TerminalWindow)?.tabColor ?? .none

            if let p = pwd { tabPwds.append(p) }

            return TabItem(
                id: wid,
                title: w.title,
                pwd: pwd,
                gitDiffStats: diffStats,
                surfaceId: sid,
                statusEntries: entries,
                needsAttention: attentionWindows.contains(wid),
                tabColor: color,
                faviconImage: favicon,
                window: w
            )
        }

        // Sweep stale Claude sessions (every 30s) — detects crashed Claude processes
        if Date().timeIntervalSince(lastPidSweepTime) >= Self.pidSweepInterval {
            lastPidSweepTime = Date()
            metadataStore.sweepStaleClaude()
        }

        // Refresh git stats in the background periodically
        let isWindowActive = window.isKeyWindow || NSApp.isActive
        let shouldRefreshGitStats = isWindowActive && Date().timeIntervalSince(gitStatsCacheTime) >= Self.gitStatsCacheInterval
        if shouldRefreshGitStats {
            gitStatsCacheTime = Date()
            let pwds = tabPwds
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var newStats: [String: String?] = [:]
                for pwd in pwds {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                    process.arguments = ["diff", "--shortstat", "HEAD"]
                    process.currentDirectoryURL = URL(fileURLWithPath: pwd)
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = Pipe()
                    guard (try? process.run()) != nil else { newStats[pwd] = nil; continue }
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { newStats[pwd] = nil; continue }
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    guard let output = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        !output.isEmpty else { newStats[pwd] = nil; continue }
                    var ins = 0, del = 0
                    if let r = output.range(of: #"\d+ insertion"#, options: .regularExpression) {
                        ins = Int(output[r].split(separator: " ")[0]) ?? 0
                    }
                    if let r = output.range(of: #"\d+ deletion"#, options: .regularExpression) {
                        del = Int(output[r].split(separator: " ")[0]) ?? 0
                    }
                    newStats[pwd] = (ins == 0 && del == 0) ? nil : "+\(ins) -\(del)"
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    // Clear all checked pwds first — assigning nil to a
                    // [String: String?] dict removes the key rather than
                    // storing nil, so stale entries would never be cleared.
                    for pwd in pwds {
                        self.gitStatsCache.removeValue(forKey: pwd)
                    }
                    for (pwd, stats) in newStats {
                        self.gitStatsCache[pwd] = stats
                    }
                    self.refresh(reason: "git stats completed")
                }
            }
        }

        let tabsChanged = newTabs != tabs
        if tabsChanged {
            tabs = newTabs
        }

        let currentSelectedID = ObjectIdentifier(selectedWindow)
        if selectedTabID != currentSelectedID {
            selectedTabID = currentSelectedID
        }
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
        let tabWindows: [NSWindow]
        if let tabbedWindows = window.tabbedWindows, !tabbedWindows.isEmpty {
            tabWindows = tabbedWindows
        } else {
            return
        }
        for w in tabWindows where ObjectIdentifier(w) != tab.id {
            if let controller = w.windowController as? TerminalController {
                controller.closeTab(nil)
            }
        }
    }

    func moveTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard let window else { return }
        guard let tabbedWindows = window.tabbedWindows, !tabbedWindows.isEmpty else { return }
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < tabbedWindows.count,
              destinationIndex >= 0, destinationIndex < tabbedWindows.count else { return }

        let movingWindow = tabbedWindows[sourceIndex]
        let targetWindow = tabbedWindows[destinationIndex]

        if sourceIndex > destinationIndex {
            targetWindow.addTabbedWindow(movingWindow, ordered: .below)
        } else {
            targetWindow.addTabbedWindow(movingWindow, ordered: .above)
        }

        if let selectedWindow = window.tabGroup?.selectedWindow {
            selectedWindow.makeKeyAndOrderFront(nil)
        }

        refresh()
    }

    func closeTabsToTheRight(of tab: TabItem) {
        guard let window else { return }
        let tabWindows: [NSWindow]
        if let tabbedWindows = window.tabbedWindows, !tabbedWindows.isEmpty {
            tabWindows = tabbedWindows
        } else {
            return
        }
        guard let idx = tabWindows.firstIndex(where: { ObjectIdentifier($0) == tab.id }) else { return }
        for w in tabWindows[(idx + 1)...] {
            if let controller = w.windowController as? TerminalController {
                controller.closeTab(nil)
            }
        }
    }
}
