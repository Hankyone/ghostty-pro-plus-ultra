import Foundation
import CoreServices

/// Watches project directories for file changes using FSEvents and runs
/// `git diff --shortstat HEAD` to produce compact "+N -N" stats strings.
///
/// Each project root gets its own watcher and git process, so one slow repo
/// can't block another. A 2-second debounce collapses rapid file writes into
/// a single git invocation. A 30-second fallback poll catches any edge cases
/// that FSEvents might miss.
final class GitStatsWatcher {

    /// Shared instance — all SidebarTabManager instances read from the same
    /// stats store so switching tabs never loses project-level git stats.
    static let shared = GitStatsWatcher()

    /// Current stats keyed by project root path. `nil` value = no changes.
    private(set) var stats: [String: String] = [:]

    /// Called on the main thread whenever stats change.
    /// Multiple managers can register; all are notified.
    private var changeCallbacks: [ObjectIdentifier: () -> Void] = [:]

    func addChangeObserver(id: ObjectIdentifier, callback: @escaping () -> Void) {
        changeCallbacks[id] = callback
    }

    func removeChangeObserver(id: ObjectIdentifier) {
        changeCallbacks.removeValue(forKey: id)
    }

    private func notifyObservers() {
        for callback in changeCallbacks.values {
            callback()
        }
    }

    private var watchers: [String: ProjectWatcher] = [:]
    private var fallbackTimer: Timer?

    private init() {
        // 30-second fallback poll to self-correct if FSEvents misses something.
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.refreshAll()
        }
    }

    // MARK: - Public API

    /// Ensure we're watching the given set of project roots.
    /// Starts watchers for new roots, stops watchers for removed roots.
    func sync(projectRoots: Set<String>) {
        let current = Set(watchers.keys)

        // Stop watchers for projects no longer visible
        for root in current.subtracting(projectRoots) {
            watchers[root]?.stop()
            watchers.removeValue(forKey: root)
            stats.removeValue(forKey: root)
        }

        // Start watchers for new projects
        for root in projectRoots.subtracting(current) {
            let watcher = ProjectWatcher(root: root) { [weak self] root, stat in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let old = self.stats[root]
                    if stat != old {
                        if let stat {
                            self.stats[root] = stat
                        } else {
                            self.stats.removeValue(forKey: root)
                        }
                        self.notifyObservers()
                    }
                }
            }
            watchers[root] = watcher
            watcher.start()
        }
    }

    /// Force-refresh all watched projects (used by the fallback timer).
    func refreshAll() {
        for watcher in watchers.values {
            watcher.refreshNow()
        }
    }

    /// Stop all watchers and clean up.
    func stopAll() {
        for watcher in watchers.values {
            watcher.stop()
        }
        watchers.removeAll()
        stats.removeAll()
    }
}

// MARK: - Per-Project Watcher

private final class ProjectWatcher {
    let root: String
    private let callback: (String, String?) -> Void

    private var stream: FSEventStreamRef?
    private var debounceWorkItem: DispatchWorkItem?
    private var isRunningGit = false
    private var needsRefreshAfterCurrentRun = false

    /// Context pointer passed to the FSEvents callback. Must be retained
    /// for the lifetime of the stream.
    private var contextSelf: Unmanaged<ProjectWatcher>?

    init(root: String, callback: @escaping (String, String?) -> Void) {
        self.root = root
        self.callback = callback
    }

    deinit {
        stop()
    }

    func start() {
        guard stream == nil else { return }

        // Retain self so the C callback can recover the object.
        contextSelf = Unmanaged.passRetained(self)

        var context = FSEventStreamContext(
            version: 0,
            info: contextSelf!.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let paths = [root as CFString] as CFArray
        stream = FSEventStreamCreate(
            nil,
            fsEventsCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0, // Latency — FSEvents batches events within this window
            UInt32(
                kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagIgnoreSelf
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
            )
        )

        guard let stream else {
            contextSelf?.release()
            contextSelf = nil
            return
        }

        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)

        // Run an initial git diff immediately.
        runGitDiff()
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil

        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }

        if let ctx = contextSelf {
            ctx.release()
            contextSelf = nil
        }
    }

    /// Schedule a debounced git diff. Called when FSEvents fires.
    func scheduleRefresh() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.runGitDiff()
        }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    /// Force an immediate refresh (used by the 30s fallback timer).
    func refreshNow() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        runGitDiff()
    }

    /// Run `git diff --shortstat HEAD` on a background thread.
    private func runGitDiff() {
        guard !isRunningGit else {
            // A refresh was requested while git is running — remember it
            // so we re-run when the current process finishes.
            needsRefreshAfterCurrentRun = true
            return
        }
        isRunningGit = true
        needsRefreshAfterCurrentRun = false

        let projectRoot = root
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.gitDiffStats(at: projectRoot)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunningGit = false

                // Only update stats on success. On error/timeout, preserve
                // the last known good value so we don't flash "clean" when
                // git is just slow or temporarily unavailable.
                if case .success(let stats) = result {
                    self.callback(self.root, stats)
                }

                // If changes arrived while we were running, re-trigger.
                if self.needsRefreshAfterCurrentRun {
                    self.needsRefreshAfterCurrentRun = false
                    self.runGitDiff()
                }
            }
        }
    }

    private enum GitResult {
        case success(String?)  // nil = clean repo, String = "+N -N"
        case error             // git failed, timed out, or not available
    }

    /// Run `git diff --shortstat HEAD` synchronously (call from background thread).
    private static func gitDiffStats(at dir: String) -> GitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["diff", "--shortstat", "HEAD"]
        process.currentDirectoryURL = URL(fileURLWithPath: dir)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return .error }

        // Timeout: kill the process if it takes more than 10 seconds.
        let deadline = DispatchTime.now() + .seconds(10)
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        if done.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return .error
        }

        guard process.terminationStatus == 0 else { return .error }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !output.isEmpty else { return .success(nil) }

        var ins = 0, del = 0
        if let r = output.range(of: #"\d+ insertion"#, options: .regularExpression) {
            ins = Int(output[r].split(separator: " ")[0]) ?? 0
        }
        if let r = output.range(of: #"\d+ deletion"#, options: .regularExpression) {
            del = Int(output[r].split(separator: " ")[0]) ?? 0
        }
        return .success((ins == 0 && del == 0) ? nil : "+\(ins) -\(del)")
    }
}

// MARK: - FSEvents C Callback

private func fsEventsCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ clientCallBackInfo: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let watcher = Unmanaged<ProjectWatcher>.fromOpaque(info).takeUnretainedValue()

    // Any file change in the project tree (working tree edits, .git index
    // updates from commits/checkouts/stashes, etc.) triggers a debounced
    // git diff refresh.
    watcher.scheduleRefresh()
}
