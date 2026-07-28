import Cocoa
import Combine
import os.log

/// App-wide engine behind every sidebar.
///
/// Exactly one instance exists. It owns the refresh timer, all notification
/// observers, the metadata subscriptions, and every cache — and rebuilds the
/// tab model **once per tab group** per change, no matter how many windows
/// (and therefore sidebars) exist. Each window's `SidebarTabManager` is a
/// thin registered façade that receives the slice for its tab group.
///
/// This replaces the previous design where every tab window ran its own
/// 0.5s timer and rebuilt the entire tab list independently: with N tabs
/// that was N managers × N tabs of work per tick — O(N²) per second on the
/// main thread, which a `sample` of the running app showed to be essentially
/// all of its idle CPU.
@MainActor
final class SidebarStore {
    static let shared = SidebarStore()

    private static let log = Logger(
        subsystem: "com.hankyone.ghostty.sidebar", category: "store")

    typealias TabItem = SidebarTabManager.TabItem
    typealias ProjectGroup = SidebarTabManager.ProjectGroup
    typealias AgentType = SidebarTabManager.AgentType
    typealias SortMode = SidebarTabManager.SortMode
    typealias GitActionStatus = SidebarTabManager.GitActionStatus

    // MARK: - Manager Registry

    private struct WeakManager {
        weak var manager: SidebarTabManager?
    }

    private var managers: [WeakManager] = []

    /// Whether bells should trigger the sidebar attention indicator.
    /// Taken from the most recently registered manager's config.
    private var bellTriggersAttention: Bool = true

    func register(_ manager: SidebarTabManager, bellTriggersAttention: Bool) {
        managers.removeAll { $0.manager == nil || $0.manager === manager }
        managers.append(WeakManager(manager: manager))
        self.bellTriggersAttention = bellTriggersAttention
        startIfNeeded()
        // Synchronous initial build so a fresh manager has data immediately.
        // Forced: the global fingerprint may not have changed, but the new
        // manager has no data yet.
        rebuild(reason: "register", force: true)
    }

    func unregister(_ manager: SidebarTabManager) {
        managers.removeAll { $0.manager == nil || $0.manager === manager }
    }

    private var liveManagers: [SidebarTabManager] {
        managers.compactMap(\.manager).filter { !$0.isInvalidated }
    }

    // MARK: - Lifecycle

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var metadataSubscription: AnyCancellable?
    private var started = false

    private init() {}

    private func startIfNeeded() {
        guard !started else { return }
        started = true

        // Single fallback timer. The fingerprint gate at the top of rebuild()
        // makes no-change ticks nearly free; the interval mainly bounds how
        // fast window-title changes (which have no notification) propagate.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.rebuild(reason: "timer")
        }

        // Instant dot updates: any metadata change (IPC set-status from hooks
        // or shell integration) schedules a coalesced refresh instead of
        // waiting for the next timer tick.
        metadataSubscription = TabMetadataStore.shared.$entries
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.requestRefresh(reason: "metadata changed")
            }

        // Git stats changes: refresh coalesced. Unlike the previous design,
        // this does NOT invalidate the favicon cache — favicon retries are
        // handled on their own slow schedule below.
        GitStatsWatcher.shared.addChangeObserver(id: ObjectIdentifier(self)) { [weak self] in
            self?.requestRefresh(reason: "git stats changed", force: true)
        }

        let center = NotificationCenter.default

        // Key-window transitions only affect selection. Forward a cheap
        // selection sync to managers in the affected tab group instead of
        // rebuilding anything.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] notification in
                guard let self,
                      let notifWindow = notification.object as? NSWindow else { return }
                for manager in self.liveManagers where manager.isInSameTabGroup(as: notifWindow) {
                    manager.refreshSelection()
                }
            })
        }

        // Bell: respect bell-features config.
        observers.append(center.addObserver(
            forName: .terminalWindowBellDidChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, self.bellTriggersAttention,
                  let controller = notification.object as? BaseTerminalController,
                  let w = controller.window else { return }
            let hasBell = notification.userInfo?[Notification.Name.terminalWindowHasBellKey] as? Bool ?? false
            if hasBell {
                self.markAttention(window: w)
            } else {
                self.clearAttention(window: w)
            }
        })

        // Desktop notifications (OSC 9/99, command completion): always trigger
        // attention, and remember the message text so the tab row can show it
        // (e.g. Devin's "Devin finished ..." — same source cmux displays).
        observers.append(center.addObserver(
            forName: .ghosttyDesktopNotificationDidFire, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let surfaceView = notification.object as? Ghostty.SurfaceView,
                  let w = surfaceView.window else { return }
            let title = notification.userInfo?[Notification.Name.ghosttyDesktopNotificationTitleKey] as? String ?? ""
            let body = notification.userInfo?[Notification.Name.ghosttyDesktopNotificationBodyKey] as? String ?? ""
            let text = (body.isEmpty ? title : body).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                self.notificationTexts[ObjectIdentifier(w)] = text
            }
            self.markAttention(window: w)
        })

        // IPC notifications (tab.notify command): trigger attention and
        // surface the message text like desktop notifications above.
        observers.append(center.addObserver(
            forName: .ghosttyIPCNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let w = notification.object as? NSWindow else { return }
            let title = notification.userInfo?[Notification.Name.ghosttyDesktopNotificationTitleKey] as? String ?? ""
            let body = notification.userInfo?[Notification.Name.ghosttyDesktopNotificationBodyKey] as? String ?? ""
            let text = (body.isEmpty ? title : body).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text != "Ghostty" {
                self.notificationTexts[ObjectIdentifier(w)] = text
            }
            self.markAttention(window: w)
        })
    }

    // MARK: - Attention

    /// Windows that need attention, cleared when the tab is selected.
    private(set) var attentionWindows: Set<ObjectIdentifier> = []

    /// Latest desktop-notification text per window, shown as a subtitle on the
    /// tab row until the user selects the tab (cmux-style).
    private(set) var notificationTexts: [ObjectIdentifier: String] = [:]

    private func markAttention(window w: NSWindow) {
        attentionWindows.insert(ObjectIdentifier(w))
        requestRefresh(reason: "attention set", force: true)
    }

    private func clearAttention(window w: NSWindow) {
        notificationTexts.removeValue(forKey: ObjectIdentifier(w))
        guard attentionWindows.remove(ObjectIdentifier(w)) != nil else { return }
        requestRefresh(reason: "attention cleared", force: true)
    }

    /// Called by managers when the user selects a tab.
    func clearAttentionOnSelect(windowID: ObjectIdentifier) {
        attentionWindows.remove(windowID)
        notificationTexts.removeValue(forKey: windowID)
    }

    // MARK: - Refresh Scheduling

    private var refreshScheduled = false
    private var pendingForce = false

    /// Coalesce any number of refresh requests within a runloop turn into a
    /// single rebuild.
    func requestRefresh(reason: String, force: Bool = false) {
        pendingForce = pendingForce || force
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let force = self.pendingForce
            self.refreshScheduled = false
            self.pendingForce = false
            self.rebuild(reason: reason, force: force)
        }
    }

    // MARK: - Rebuild

    /// Fingerprint of the last rebuild, used to skip no-op work.
    private var lastFingerprint: Int = 0

    /// When the last publish to managers happened; used to refresh relative
    /// time labels ("3m") even when nothing else changes.
    private var lastPublishTime: Date = .distantPast

    /// Throttle for stale agent PID sweeping.
    private var lastPidSweepTime: Date = .distantPast
    private static let pidSweepInterval: TimeInterval = 30.0

    private func rebuild(reason: String, force: Bool = false) {
        let live = liveManagers
        guard !live.isEmpty else { return }

        let metadataStore = TabMetadataStore.shared

        // Periodic stale-session sweep (crashed agents leave dangling PIDs).
        let now = Date()
        if now.timeIntervalSince(lastPidSweepTime) >= Self.pidSweepInterval {
            lastPidSweepTime = now
            metadataStore.sweepStaleSessions()
        }

        // Group managers by tab group so each group is built exactly once.
        var groups: [ObjectIdentifier: (windows: [NSWindow], managers: [SidebarTabManager])] = [:]
        var groupOrder: [ObjectIdentifier] = []
        for manager in live {
            guard let window = manager.window else { continue }
            let key = ObjectIdentifier(window.tabGroup ?? window)
            if groups[key] == nil {
                groups[key] = (orderedTabWindows(for: window), [])
                groupOrder.append(key)
            }
            groups[key]?.managers.append(manager)
        }

        // Feed the screen-quiescence classifier (only observes hook-less
        // foreground processes; runs at 1Hz). Verdict changes alter the
        // fingerprint below, which is what publishes them.
        runClassifierIfNeeded(groups: groupOrder.compactMap { groups[$0] })

        // Cheap gate: skip everything when nothing observable changed.
        // Forced refreshes (git stats, attention, manual) bypass the gate
        // because their inputs aren't part of the fingerprint.
        let timeLabelsStale = now.timeIntervalSince(lastPublishTime) >= 60
        let fingerprint = globalFingerprint(
            groups: groupOrder.compactMap { groups[$0]?.windows },
            metadataStore: metadataStore
        )
        if !force && !timeLabelsStale && fingerprint == lastFingerprint { return }
        lastFingerprint = fingerprint
        lastPublishTime = now

        syncCollapsedProjects()

        for key in groupOrder {
            guard let group = groups[key] else { continue }
            let selectedWindow = group.windows.first?.tabGroup?.selectedWindow
                ?? group.managers.first?.window
            let newTabs = buildTabs(
                for: group.windows,
                selectedWindow: selectedWindow,
                metadataStore: metadataStore,
                now: now
            )
            trackActivity(for: newTabs, metadataStore: metadataStore, now: now)
            let newGroups = buildProjectGroups(from: newTabs)
            for manager in group.managers {
                manager.apply(
                    tabs: newTabs,
                    projectGroups: newGroups,
                    collapsed: collapsedProjects,
                    // Relative-time labels ("3m") are rendered from the array
                    // contents, so an unchanged array still needs a republish
                    // once labels go stale.
                    republishForTimeLabels: timeLabelsStale
                )
            }
        }

        // Prune per-tab bookkeeping for closed tabs.
        let currentIds = Set(groupOrder.flatMap { key in
            groups[key]?.windows.map { ObjectIdentifier($0) } ?? []
        })
        pruneTabState(keeping: currentIds)

        // Keep the FSEvents git watcher in sync with the projects on screen.
        let activeRoots = Set(groupOrder.flatMap { key -> [String] in
            guard let group = groups[key] else { return [] }
            return group.managers.first?.tabs.compactMap(\.projectRoot) ?? []
        })
        gitStatsWatcher.sync(projectRoots: activeRoots)
    }

    /// One fingerprint over every tab group: window identity/order, titles,
    /// pwds, and status entries. Attention count included so bell state
    /// changes republish.
    private func globalFingerprint(
        groups: [[NSWindow]],
        metadataStore: TabMetadataStore
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(attentionWindows.count)
        for windows in groups {
            hasher.combine(windows.count)
            for window in windows {
                hasher.combine(ObjectIdentifier(window))
                hasher.combine(window.title)
                hasher.combine(notificationTexts[ObjectIdentifier(window)])
                if let ctrl = window.windowController as? BaseTerminalController,
                   let surface = ctrl.focusedSurface {
                    hasher.combine(surface.id)
                    // Normalize tilde paths for fingerprint consistency
                    hasher.combine((surface.pwd as NSString?)?.expandingTildeInPath)
                    for entry in metadataStore.statusEntries(for: surface.id) {
                        hasher.combine(entry.key)
                        hasher.combine(entry.value)
                        hasher.combine(entry.icon)
                    }
                    // Indicator inputs that live outside the metadata store.
                    if let report = surface.progressReport {
                        hasher.combine(report.state)
                        hasher.combine(report.progress)
                    }
                    hasher.combine(classifierVerdicts[surface.id])
                }
                hasher.combine((window as? TerminalWindow)?.tabColor ?? .none)
            }
        }
        return hasher.finalize()
    }

    // MARK: - Tab Building

    private func buildTabs(
        for tabWindows: [NSWindow],
        selectedWindow: NSWindow?,
        metadataStore: TabMetadataStore,
        now: Date
    ) -> [TabItem] {
        tabWindows.map { w -> TabItem in
            let controller = w.windowController as? BaseTerminalController
            let surface = controller?.focusedSurface
            let wid = ObjectIdentifier(w)
            let sid = surface?.id
            let pwd = surface?.pwd
            let entries = sid.map { metadataStore.statusEntries(for: $0) } ?? []
            let projectRoot = pwd.flatMap { detectProjectRoot(at: $0) }
            let diffStats = projectRoot.flatMap { gitStatsWatcher.stats[$0] }
            let favicon = pwd.flatMap { detectFavicon(at: $0) }
            let color = (w as? TerminalWindow)?.tabColor ?? .none

            // Determine whether this tab has an unread completion.
            // Scope to the current agent via the mutually-exclusive session key.
            let agent = AgentType.detect(from: entries)
            let doneToken = agent.flatMap { a in entries.first(where: { $0.key == a.doneAtKey })?.value }
            var unread = false
            if let sid, let token = doneToken {
                if w == selectedWindow {
                    // Auto-acknowledge: user is already looking at this tab
                    metadataStore.acknowledgedDoneToken[sid] = token
                } else {
                    unread = metadataStore.acknowledgedDoneToken[sid] != token
                }
            }

            let indicator = computeIndicator(
                entries: entries,
                agent: agent,
                unread: unread,
                surface: surface,
                isSelected: w == selectedWindow,
                metadataStore: metadataStore
            )

            return TabItem(
                id: wid,
                title: w.title,
                pwd: pwd,
                gitDiffStats: diffStats,
                surfaceId: sid,
                statusEntries: entries,
                needsAttention: attentionWindows.contains(wid),
                notificationText: notificationTexts[wid],
                hasUnreadCompletion: unread,
                tabColor: color,
                faviconImage: favicon,
                window: w,
                projectRoot: projectRoot,
                lastActivity: lastActivityTime[wid],
                createdAt: tabCreationTime[wid],
                indicator: indicator
            )
        }
    }

    // MARK: - Status Indicator

    typealias TabIndicator = SidebarTabManager.TabIndicator

    /// Decide what the status dot shows, from highest-fidelity signal down:
    ///
    /// 1. **Agent hooks** (`<agent>-active` set by hook scripts over IPC):
    ///    exact working / needs-input / done states. When hooks are active
    ///    they own the dot — lower-tier signals like `process-running`
    ///    (which is true the whole time the agent's CLI runs) are ignored.
    /// 2. **Screen-quiescence classifier**: for foreground processes without
    ///    hooks (Devin, any TUI). If the screen has been still and its tail
    ///    looks like a permission/question prompt → needs input.
    /// 3. **OSC 9;4 progress reports** (Claude Code and others emit these
    ///    natively): running/error progress states.
    /// 4. **Shell integration**: `command-failed` (nonzero exit while the
    ///    tab wasn't being watched, cleared on visit) and `process-running`
    ///    (any foreground command → quiet "working" dot).
    private func computeIndicator(
        entries: [TabMetadataStore.StatusEntry],
        agent: AgentType?,
        unread: Bool,
        surface: Ghostty.SurfaceView?,
        isSelected: Bool,
        metadataStore: TabMetadataStore
    ) -> TabIndicator {
        // Tier 1: agent hook state is authoritative when present.
        if let agent, let active = entries.first(where: { $0.key == agent.activeKey }) {
            switch active.value {
            case "needs-input": return .needsInput
            case "working": return .working
            case "done": return unread ? .doneUnseen : .none
            default: break
            }
        }

        let processRunning = entries.contains(
            where: { $0.key == "process-running" && $0.value == "true" })

        // Tier 2: quiescence classifier for hook-less foreground processes.
        if processRunning, let sid = surface?.id,
           let verdict = classifierVerdicts[sid] {
            switch verdict {
            case .needsInput: return .needsInput
            case .working: return .working
            case .quiet: break  // still running; fall through to lower tiers
            }
        }

        // Tier 3: OSC 9;4 progress reports.
        if let report = surface?.progressReport {
            switch report.state {
            case .error: return .error
            case .set, .indeterminate, .pause: return .working
            case .remove: break
            }
        }

        // Tier 4: shell integration exit codes + busy state.
        if entries.contains(where: { $0.key == "command-failed" }) {
            if isSelected {
                // Visiting the tab acknowledges the failure.
                if let sid = surface?.id {
                    metadataStore.clearStatus(tabId: sid, key: "command-failed")
                }
            } else if !processRunning {
                return .error
            }
        }

        if processRunning { return .working }

        return .none
    }

    // MARK: - Screen Quiescence Classifier

    /// What the classifier concluded about a hook-less foreground process.
    private enum ClassifierVerdict: Hashable {
        /// Output flowed recently — the program is doing something.
        case working
        /// Output has been still and the screen tail looks like a
        /// permission/question prompt.
        case needsInput
        /// Output has been still with no prompt-looking tail.
        case quiet
    }

    private struct ScreenObservation {
        var contentHash: Int
        var lastChange: Date
    }

    private var screenObservations: [UUID: ScreenObservation] = [:]
    private var classifierVerdicts: [UUID: ClassifierVerdict] = [:]

    /// Output must be still this long before the tail is classified.
    /// (Spinners keep resetting the clock, so "working" never misfires.)
    private static let quiescenceThreshold: TimeInterval = 2.5

    /// Patterns that mean "this program is waiting for the user".
    /// Conservative on purpose: a false pulsing dot trains the user to
    /// ignore the sidebar. Matched case-insensitively against the last
    /// ~500 characters of the visible screen.
    private static let needsInputPatterns: [NSRegularExpression] = {
        let patterns = [
            #"\[y/n\]|\(y/n\)|\[yes/no\]"#,
            #"do you want"#,
            #"would you like"#,
            #"allow .{0,40}\?"#,
            #"approve|permission"#,
            #"press enter to (continue|confirm)"#,
            #"waiting for (your )?(input|approval|confirmation)"#,
            #"continue\?"#,
            #"❯\s*1\. yes"#,  // Claude-style option lists rendered by TUIs
        ]
        return patterns.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }()

    /// Every other 0.5s tick, watch the screens of tabs that are running a
    /// foreground process without agent hooks, and classify still screens.
    /// Reading screen text costs a full-grid extraction per tab, so this
    /// runs only for candidate tabs and only at 1Hz.
    private var classifierTickToggle = false

    private func runClassifierIfNeeded(groups: [(windows: [NSWindow], managers: [SidebarTabManager])]) {
        classifierTickToggle.toggle()
        guard classifierTickToggle else { return }

        let metadataStore = TabMetadataStore.shared
        let now = Date()
        var liveSurfaceIds = Set<UUID>()

        for group in groups {
            for w in group.windows {
                guard let controller = w.windowController as? BaseTerminalController,
                      let surface = controller.focusedSurface else { continue }
                let sid = surface.id
                liveSurfaceIds.insert(sid)

                let entries = metadataStore.statusEntries(for: sid)
                // Candidates: foreground process running, no agent hook state.
                let processRunning = entries.contains(
                    where: { $0.key == "process-running" && $0.value == "true" })
                let agent = AgentType.detect(from: entries)
                let hasHookState = agent.map { a in
                    entries.contains(where: { $0.key == a.activeKey })
                } ?? false

                guard processRunning && !hasHookState else {
                    screenObservations.removeValue(forKey: sid)
                    classifierVerdicts.removeValue(forKey: sid)
                    continue
                }

                let text = surface.cachedScreenContents.get()
                var hasher = Hasher()
                hasher.combine(text)
                let hash = hasher.finalize()

                if var obs = screenObservations[sid] {
                    if obs.contentHash != hash {
                        obs.contentHash = hash
                        obs.lastChange = now
                        screenObservations[sid] = obs
                        classifierVerdicts[sid] = .working
                    } else if now.timeIntervalSince(obs.lastChange) >= Self.quiescenceThreshold {
                        classifierVerdicts[sid] = classifyTail(of: text)
                    }
                } else {
                    screenObservations[sid] = ScreenObservation(contentHash: hash, lastChange: now)
                    classifierVerdicts[sid] = .working
                }
            }
        }

        screenObservations = screenObservations.filter { liveSurfaceIds.contains($0.key) }
        classifierVerdicts = classifierVerdicts.filter { liveSurfaceIds.contains($0.key) }
    }

    /// Classify the tail of a still screen: does it look like a prompt
    /// waiting for the user?
    private func classifyTail(of text: String) -> ClassifierVerdict {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .quiet }
        let tail = String(trimmed.suffix(500))
        let range = NSRange(tail.startIndex..<tail.endIndex, in: tail)
        for regex in Self.needsInputPatterns {
            if regex.firstMatch(in: tail, options: [], range: range) != nil {
                return .needsInput
            }
        }
        return .quiet
    }

    // MARK: - Activity Tracking

    /// Tracks when each tab's observable state last changed, for "Last activity" sorting.
    private var lastActivityTime: [ObjectIdentifier: Date] = [:]
    private var previousTabFingerprints: [ObjectIdentifier: Int] = [:]
    private var tabCreationTime: [ObjectIdentifier: Date] = [:]
    private var tabFirstSeenTime: [ObjectIdentifier: Date] = [:]
    private var previousTabTitles: [ObjectIdentifier: String] = [:]

    private func trackActivity(
        for newTabs: [TabItem],
        metadataStore: TabMetadataStore,
        now: Date
    ) {
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
                // shell initialization (first 5s) and session-resume startup
                // (pid present but no active key yet).
                let firstSeen = tabFirstSeenTime[tab.id] ?? .distantPast
                let isShellInit = now.timeIntervalSince(firstSeen) < 5.0
                let isSessionResuming: Bool = {
                    let hasPid = tab.statusEntries.contains(where: { entry in
                        AgentType.allCases.contains { $0.pidKey == entry.key }
                    })
                    let hasActive = tab.statusEntries.contains(where: { entry in
                        AgentType.allCases.contains { $0.activeKey == entry.key }
                    })
                    return hasPid && !hasActive
                }()

                // Titles are compared by string equality (not hashed) so that
                // re-emission of the same title on tab selection is ignored.
                let titleChanged = previousTabTitles[tab.id] != tab.title

                if (prev != fp || titleChanged) && !isShellInit && !isSessionResuming {
                    lastActivityTime[tab.id] = now
                    if let sid = tab.surfaceId {
                        metadataStore.setStatus(tabId: sid, key: "last-activity",
                            value: String(Int(now.timeIntervalSince1970)))
                    }
                }
            }
            // First time seeing a tab: restore persisted activity/creation times.
            if previousTabFingerprints[tab.id] == nil {
                tabFirstSeenTime[tab.id] = now
                recordTabCreationTime(tab.id, surfaceId: tab.surfaceId)
                if let sid = tab.surfaceId,
                   let entry = metadataStore.entries[sid]?["last-activity"],
                   let epoch = Double(entry.value) {
                    lastActivityTime[tab.id] = Date(timeIntervalSince1970: epoch)
                } else {
                    lastActivityTime[tab.id] = tabCreationTime[tab.id]
                }
            }
            previousTabFingerprints[tab.id] = fp
            previousTabTitles[tab.id] = tab.title
        }
    }

    private func pruneTabState(keeping currentIds: Set<ObjectIdentifier>) {
        lastActivityTime = lastActivityTime.filter { currentIds.contains($0.key) }
        tabCreationTime = tabCreationTime.filter { currentIds.contains($0.key) }
        tabFirstSeenTime = tabFirstSeenTime.filter { currentIds.contains($0.key) }
        previousTabFingerprints = previousTabFingerprints.filter { currentIds.contains($0.key) }
        previousTabTitles = previousTabTitles.filter { currentIds.contains($0.key) }
    }

    /// Record creation time for a tab if not already tracked.
    /// Persists to TabMetadataStore so the timestamp survives app restarts.
    private func recordTabCreationTime(_ tabId: ObjectIdentifier, surfaceId: UUID?) {
        guard tabCreationTime[tabId] == nil else { return }
        let store = TabMetadataStore.shared
        if let sid = surfaceId,
           let entry = store.entries[sid]?["tab-created-at"],
           let epoch = Double(entry.value) {
            tabCreationTime[tabId] = Date(timeIntervalSince1970: epoch)
        } else {
            let now = Date()
            tabCreationTime[tabId] = now
            if let sid = surfaceId {
                store.setStatus(tabId: sid, key: "tab-created-at",
                    value: String(Int(now.timeIntervalSince1970)))
            }
        }
    }

    // MARK: - Tab Ordering

    private static let orderLog = Logger(
        subsystem: "com.hankyone.ghostty.sidebar", category: "order")

    /// Persisted manual ordering of tabs by surface UUID string.
    private var manualTabOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: "SidebarManualTabOrder") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "SidebarManualTabOrder") }
    }

    /// Returns the logical tab order for the given window's tab group.
    /// AppKit's live window arrays can shift when the selected tab changes,
    /// so we resolve them through a persisted surface-ID order first.
    func orderedTabWindows(for window: NSWindow) -> [NSWindow] {
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

    private func appKitTabWindows(for window: NSWindow) -> [NSWindow] {
        if let groupWindows = window.tabGroup?.windows, !groupWindows.isEmpty {
            return groupWindows
        }
        if let tabbedWindows = window.tabbedWindows, !tabbedWindows.isEmpty {
            return tabbedWindows
        }
        return [window]
    }

    /// Surface UUID string used for persisted tab ordering.
    func tabOrderKey(for window: NSWindow) -> String? {
        guard let controller = window.windowController as? BaseTerminalController,
              let surfaceId = controller.focusedSurface?.id else { return nil }
        return surfaceId.uuidString
    }

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

    /// Replace a tab group's slice of the persisted order after a drag reorder.
    func persistTabOrder(_ reorderedGroupIds: [String], for windows: [NSWindow]) {
        guard !reorderedGroupIds.isEmpty else { return }

        var order = syncManualTabOrder(with: windows)
        let groupIdSet = Set(windows.compactMap { tabOrderKey(for: $0) })
        let insertionIndex = order.firstIndex(where: { groupIdSet.contains($0) }) ?? order.count

        order.removeAll { groupIdSet.contains($0) }
        order.insert(contentsOf: reorderedGroupIds, at: insertionIndex)
        manualTabOrder = order
    }

    // MARK: - Sorting & Grouping

    var projectSortMode: SortMode {
        get {
            SortMode(rawValue: UserDefaults.standard.string(forKey: "SidebarProjectSort") ?? "") ?? .manual
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "SidebarProjectSort")
            requestRefresh(reason: "sort mode changed", force: true)
        }
    }

    /// Collapsed project group IDs, persisted to UserDefaults.
    private(set) var collapsedProjects: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "SidebarCollapsedProjects") ?? []
    )

    func toggleProjectCollapsed(_ groupId: String) {
        if collapsedProjects.contains(groupId) {
            collapsedProjects.remove(groupId)
        } else {
            collapsedProjects.insert(groupId)
        }
        UserDefaults.standard.set(Array(collapsedProjects), forKey: "SidebarCollapsedProjects")
        for manager in liveManagers {
            manager.applyCollapsed(collapsedProjects)
        }
    }

    private func syncCollapsedProjects() {
        let saved = Set(UserDefaults.standard.stringArray(forKey: "SidebarCollapsedProjects") ?? [])
        if saved != collapsedProjects {
            collapsedProjects = saved
        }
    }

    /// Persisted manual ordering of project roots.
    private var manualProjectOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: "SidebarManualProjectOrder") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "SidebarManualProjectOrder") }
    }

    /// Reorder a project group from one index to another (for manual sort).
    func moveProjectGroup(fromId: String, toId: String, currentGroups: [ProjectGroup]) {
        var order = manualProjectOrder
        let currentIds = currentGroups.filter({ !$0.isOtherGroup }).map(\.id)
        for id in currentIds where !order.contains(id) {
            order.append(id)
        }
        guard let fromIdx = order.firstIndex(of: fromId),
              let toIdx = order.firstIndex(of: toId) else { return }
        let item = order.remove(at: fromIdx)
        order.insert(item, at: toIdx)
        manualProjectOrder = order
        requestRefresh(reason: "project reorder", force: true)
    }

    /// Build project groups from a tab list.
    func buildProjectGroups(from tabs: [TabItem]) -> [ProjectGroup] {
        var projectTabs: [String: [TabItem]] = [:]
        var projectOrder: [String] = []
        var homeTabs: [TabItem] = []
        var otherTabs: [TabItem] = []

        // Bucket by the tab's own group id (the single source of truth) so the
        // display grouping and the drag-and-drop validator can never disagree.
        for tab in tabs {
            switch tab.groupID {
            case "__home__": homeTabs.append(tab)
            case "__other__": otherTabs.append(tab)
            case let root:
                if projectTabs[root] == nil {
                    projectOrder.append(root)
                }
                projectTabs[root, default: []].append(tab)
            }
        }

        var groups: [ProjectGroup] = []

        for root in projectOrder {
            guard var rootTabs = projectTabs[root] else { continue }
            sortTabs(&rootTabs)

            groups.append(ProjectGroup(
                id: root,
                name: (root as NSString).lastPathComponent,
                projectRoot: root,
                tabs: rootTabs,
                faviconImage: rootTabs.first?.faviconImage,
                gitDiffStats: gitStatsWatcher.stats[root]
            ))
        }

        switch projectSortMode {
        case .lastActivity:
            groups.sort { a, b in
                let aTime = a.tabs.compactMap({ lastActivityTime[$0.id] }).max() ?? .distantPast
                let bTime = b.tabs.compactMap({ lastActivityTime[$0.id] }).max() ?? .distantPast
                return aTime > bTime
            }
        case .createdAt:
            groups.sort { a, b in
                let aTime = a.tabs.compactMap({ tabCreationTime[$0.id] }).min() ?? .distantPast
                let bTime = b.tabs.compactMap({ tabCreationTime[$0.id] }).min() ?? .distantPast
                return aTime < bTime
            }
        case .manual:
            var order = manualProjectOrder
            let currentIds = Set(groups.map(\.id))
            var changed = false
            for id in groups.map(\.id) where !order.contains(id) {
                order.append(id)
                changed = true
            }
            order = order.filter { currentIds.contains($0) }
            if changed { manualProjectOrder = order }

            groups.sort { a, b in
                let aIdx = order.firstIndex(of: a.id) ?? Int.max
                let bIdx = order.firstIndex(of: b.id) ?? Int.max
                return aIdx < bIdx
            }
        }

        if !homeTabs.isEmpty {
            sortTabs(&homeTabs)
            groups.append(ProjectGroup(
                id: "__home__", name: "Home", projectRoot: nil,
                tabs: homeTabs, faviconImage: nil, gitDiffStats: nil
            ))
        }

        if !otherTabs.isEmpty {
            sortTabs(&otherTabs)
            groups.append(ProjectGroup(
                id: "__other__", name: "Other", projectRoot: nil,
                tabs: otherTabs, faviconImage: nil, gitDiffStats: nil
            ))
        }

        return groups
    }

    private func sortTabs(_ tabs: inout [TabItem]) {
        switch projectSortMode {
        case .createdAt:
            tabs.sort { a, b in
                (tabCreationTime[a.id] ?? .distantPast) < (tabCreationTime[b.id] ?? .distantPast)
            }
        case .lastActivity:
            tabs.sort { a, b in
                (lastActivityTime[a.id] ?? .distantPast) > (lastActivityTime[b.id] ?? .distantPast)
            }
        case .manual:
            break
        }
    }

    // MARK: - Project Root Detection

    private var gitStatsWatcher: GitStatsWatcher { GitStatsWatcher.shared }

    /// Cache of detected project roots keyed by pwd.
    private var projectRootCache: [String: String?] = [:]

    /// Project root marker files, in priority order.
    private static let projectRootMarkers = [
        ".git", "package.json", "Cargo.toml", "go.mod",
        "pyproject.toml", "Gemfile", "pom.xml", "build.gradle",
    ]

    private func detectProjectRoot(at pwd: String) -> String? {
        if let cached = projectRootCache[pwd] {
            return cached
        }
        let result = Self.findProjectRoot(at: pwd)
        projectRootCache[pwd] = result
        return result
    }

    /// Walk up from `pwd` looking for a directory containing a project root marker.
    /// The home directory is never treated as a project root.
    nonisolated private static func findProjectRoot(at pwd: String) -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        // Expand tilde paths (e.g., ~/macdown -> /Users/hankyone/macdown)
        var dir = (pwd as NSString).expandingTildeInPath
        while dir != "/" && dir.hasPrefix("/Users") {
            if dir == home { return nil }
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

    // MARK: - Favicon Detection

    /// Cache of detected favicons keyed by pwd.
    private var faviconCache: [String: NSImage?] = [:]

    /// Next allowed retry time for pwds whose scan found no favicon.
    /// Prevents the previous behavior of re-walking every icon-less project's
    /// directory tree every 30 seconds forever.
    private var faviconRetryAt: [String: Date] = [:]
    private static let faviconRetryInterval: TimeInterval = 300

    /// Pwds currently being detected in the background.
    private var faviconDetectionInFlight: Set<String> = []

    private func detectFavicon(at pwd: String) -> NSImage? {
        if let cached = faviconCache[pwd] {
            if cached != nil { return cached }
            // Negative result: retry occasionally, not on every rebuild.
            if let retryAt = faviconRetryAt[pwd], Date() < retryAt { return nil }
        }

        if !faviconDetectionInFlight.contains(pwd) {
            faviconDetectionInFlight.insert(pwd)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let result = SidebarFaviconFinder.find(at: pwd)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.faviconDetectionInFlight.remove(pwd)
                    self.faviconCache[pwd] = result
                    if result == nil {
                        self.faviconRetryAt[pwd] = Date().addingTimeInterval(Self.faviconRetryInterval)
                    } else {
                        self.faviconRetryAt.removeValue(forKey: pwd)
                        self.requestRefresh(reason: "favicon detected", force: true)
                    }
                }
            }
        }
        return faviconCache[pwd] ?? nil
    }

    // MARK: - Git Actions

    /// Per-project git action state — `.inProgress` while running, `.error` on failure.
    private(set) var gitActionState: [String: GitActionStatus] = [:]

    /// Timers that auto-dismiss error states after 5 seconds.
    private var gitErrorDismissTimers: [String: DispatchWorkItem] = [:]

    func gitActionStatus(forProjectRoot root: String?) -> GitActionStatus? {
        guard let root else { return nil }
        return gitActionState[root]
    }

    private func setGitActionState(_ status: GitActionStatus?, forProjectRoot root: String) {
        if let status {
            gitActionState[root] = status
        } else {
            gitActionState.removeValue(forKey: root)
        }
        for manager in liveManagers {
            manager.noteGitActionChanged()
        }
    }

    private func scheduleErrorDismiss(forProjectRoot root: String) {
        gitErrorDismissTimers[root]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.setGitActionState(nil, forProjectRoot: root)
            self?.gitErrorDismissTimers.removeValue(forKey: root)
        }
        gitErrorDismissTimers[root] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: item)
    }

    /// Run git commit with an AI-generated commit message for a project.
    func gitCommit(projectRoot: String) {
        guard gitActionState[projectRoot] != .inProgress else { return }
        gitErrorDismissTimers[projectRoot]?.cancel()
        gitErrorDismissTimers.removeValue(forKey: projectRoot)
        setGitActionState(.inProgress, forProjectRoot: projectRoot)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = SidebarGitActions.performGitCommit(at: projectRoot)
            DispatchQueue.main.async {
                guard let self else { return }
                self.gitStatsWatcher.refreshAll()
                switch result {
                case .success:
                    self.setGitActionState(nil, forProjectRoot: projectRoot)
                case .error(let message):
                    self.setGitActionState(.error(message), forProjectRoot: projectRoot)
                    self.scheduleErrorDismiss(forProjectRoot: projectRoot)
                }
            }
        }
    }

    /// Push the current branch to remote for a project.
    func gitPush(projectRoot: String) {
        guard gitActionState[projectRoot] != .inProgress else { return }
        gitErrorDismissTimers[projectRoot]?.cancel()
        gitErrorDismissTimers.removeValue(forKey: projectRoot)
        setGitActionState(.inProgress, forProjectRoot: projectRoot)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = SidebarGitActions.performGitPush(at: projectRoot)
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.setGitActionState(nil, forProjectRoot: projectRoot)
                case .error(let message):
                    self.setGitActionState(.error(message), forProjectRoot: projectRoot)
                    self.scheduleErrorDismiss(forProjectRoot: projectRoot)
                }
            }
        }
    }

    /// Commit all changes and push in one action.
    func gitCommitAndPush(projectRoot: String) {
        guard gitActionState[projectRoot] != .inProgress else { return }
        gitErrorDismissTimers[projectRoot]?.cancel()
        gitErrorDismissTimers.removeValue(forKey: projectRoot)
        setGitActionState(.inProgress, forProjectRoot: projectRoot)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let commitResult = SidebarGitActions.performGitCommit(at: projectRoot)
            guard case .success = commitResult else {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.gitStatsWatcher.refreshAll()
                    if case .error(let message) = commitResult {
                        self.setGitActionState(.error(message), forProjectRoot: projectRoot)
                        self.scheduleErrorDismiss(forProjectRoot: projectRoot)
                    }
                }
                return
            }
            let pushResult = SidebarGitActions.performGitPush(at: projectRoot)
            DispatchQueue.main.async {
                guard let self else { return }
                self.gitStatsWatcher.refreshAll()
                switch pushResult {
                case .success:
                    self.setGitActionState(nil, forProjectRoot: projectRoot)
                case .error(let message):
                    self.setGitActionState(.error(message), forProjectRoot: projectRoot)
                    self.scheduleErrorDismiss(forProjectRoot: projectRoot)
                }
            }
        }
    }
}
