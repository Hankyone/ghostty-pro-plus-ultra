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
        let isSelected: Bool
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
            lhs.id == rhs.id && lhs.title == rhs.title && lhs.isSelected == rhs.isSelected
                && lhs.pwd == rhs.pwd && lhs.gitDiffStats == rhs.gitDiffStats
                && lhs.surfaceId == rhs.surfaceId
                && lhs.statusEntries == rhs.statusEntries
                && lhs.needsAttention == rhs.needsAttention
                && lhs.tabColor == rhs.tabColor
                && lhs.faviconImage === rhs.faviconImage
        }
    }

    @Published var tabs: [TabItem] = []

    /// Windows that need attention, cleared when the tab is selected.
    private var attentionWindows: Set<ObjectIdentifier> = []

    /// Whether bells should trigger the sidebar attention indicator.
    /// Derived from `bell-features` containing `attention`.
    private let bellTriggersAttention: Bool

    /// Cache of detected favicons keyed by pwd to avoid re-scanning every refresh.
    private var faviconCache: [String: NSImage?] = [:]

    /// Cache for git diff stats to avoid spawning git every 0.5s.
    private var gitStatsCache: [String: String?] = [:]
    private var gitStatsCacheTime: Date = .distantPast
    private static let gitStatsCacheInterval: TimeInterval = 5.0

    /// Throttle for stale Claude PID sweeping (every 30s).
    private var lastPidSweepTime: Date = .distantPast
    private static let pidSweepInterval: TimeInterval = 30.0

    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    init(window: NSWindow, bellTriggersAttention: Bool = true) {
        self.window = window
        self.bellTriggersAttention = bellTriggersAttention
        setupObservers()
        refresh()
    }

    deinit {
        timer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func setupObservers() {
        let center = NotificationCenter.default

        let titleObserver = center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refresh() }
        observers.append(titleObserver)

        let resignObserver = center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refresh() }
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
                    self.refresh()
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
            self?.refresh()
        }
    }

    // MARK: - Attention

    private func markAttention(window w: NSWindow) {
        attentionWindows.insert(ObjectIdentifier(w))
        refresh()
    }

    private func clearAttention(for id: ObjectIdentifier) {
        attentionWindows.remove(id)
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
    private func detectFavicon(at pwd: String) -> NSImage? {
        // Return cached result if available
        if let cached = faviconCache[pwd] {
            return cached
        }

        let fm = FileManager.default
        let result = findFavicon(at: pwd, using: fm)
        faviconCache[pwd] = result
        return result
    }

    /// Fallback icon filenames when no favicon.* is found.
    private static let fallbackIconNames = [
        "icon-32x32.png", "icon-48x48.png", "icon-192x192.png",
        "apple-touch-icon.png", "logo.svg", "logo.png",
    ]

    private func findFavicon(at pwd: String, using fm: FileManager) -> NSImage? {
        var dir = pwd
        while dir != "/" && dir.hasPrefix("/Users") {
            let isProjectRoot = fm.fileExists(atPath: (dir as NSString).appendingPathComponent("package.json"))
                || fm.fileExists(atPath: (dir as NSString).appendingPathComponent(".git"))
                || fm.fileExists(atPath: (dir as NSString).appendingPathComponent("Cargo.toml"))
                || fm.fileExists(atPath: (dir as NSString).appendingPathComponent("go.mod"))

            if isProjectRoot {
                for searchDir in Self.faviconSearchDirs {
                    let base = searchDir.isEmpty ? dir : (dir as NSString).appendingPathComponent(searchDir)
                    // Try standard favicon.{ext}
                    for ext in Self.faviconExtensions {
                        let path = (base as NSString).appendingPathComponent("favicon.\(ext)")
                        if let image = loadFavicon(at: path) { return image }
                    }
                    // Try sized variants and fallback names
                    let sized = (base as NSString).appendingPathComponent("favicon-32x32.png")
                    if let image = loadFavicon(at: sized) { return image }

                    for name in Self.fallbackIconNames {
                        let path = (base as NSString).appendingPathComponent(name)
                        if let image = loadFavicon(at: path) { return image }
                    }
                }
                return nil  // Found project root but no favicon
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    private func loadFavicon(at path: String) -> NSImage? {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: 12, height: 12)
        return image
    }

    // MARK: - Refresh

    func refresh() {
        guard let window else { return }

        let tabWindows: [NSWindow]
        if let tabbedWindows = window.tabbedWindows, !tabbedWindows.isEmpty {
            tabWindows = tabbedWindows
        } else {
            tabWindows = [window]
        }

        let selectedWindow = window.tabGroup?.selectedWindow ?? window
        let metadataStore = TabMetadataStore.shared

        // Collect pwds for background git refresh
        var tabPwds: [String] = []

        let newTabs = tabWindows.map { w -> TabItem in
            let controller = w.windowController as? BaseTerminalController
            let surface = controller?.focusedSurface
            let wid = ObjectIdentifier(w)
            let sid = surface?.id
            let pwd = surface?.pwd
            let entries = sid.map { metadataStore.statusEntries(for: $0) } ?? []
            // Always use cached git stats (never block the main thread)
            let diffStats = pwd.flatMap { gitStatsCache[$0] ?? nil }
            let favicon = pwd.flatMap { detectFavicon(at: $0) }
            let color = (w as? TerminalWindow)?.tabColor ?? .none

            if let p = pwd { tabPwds.append(p) }

            return TabItem(
                id: wid,
                title: w.title,
                pwd: pwd,
                gitDiffStats: diffStats,
                surfaceId: sid,
                statusEntries: entries,
                isSelected: w === selectedWindow,
                needsAttention: attentionWindows.contains(wid) && w !== selectedWindow,
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
        if isWindowActive && Date().timeIntervalSince(gitStatsCacheTime) >= Self.gitStatsCacheInterval {
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
                    for (pwd, stats) in newStats {
                        self.gitStatsCache[pwd] = stats
                    }
                    self.refresh()
                }
            }
        }

        if newTabs != tabs {
            tabs = newTabs
        }
    }

    // MARK: - Tab Actions

    func createNewTab() {
        NSApp.sendAction(#selector(TerminalController.newTab(_:)), to: nil, from: nil)
    }

    func selectTab(_ tab: TabItem) {
        clearAttention(for: tab.id)
        tab.window.makeKeyAndOrderFront(nil)
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
