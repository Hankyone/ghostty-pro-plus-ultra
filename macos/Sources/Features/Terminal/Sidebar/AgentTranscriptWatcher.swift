import Foundation

/// Reads what a coding agent is actually doing from the transcript it writes
/// to disk, and keeps that reading current as the file grows.
///
/// The sidebar used to learn an agent's state only from hooks the agent fires
/// at us. Hooks are a side channel: they arrive out of band, they can be
/// dropped, and three of the agents we support never had them wired up at all.
/// The transcript is the conversation itself, so it can't disagree with what
/// the user is looking at, and it carries detail a hook never sent — whether
/// the model is reasoning, which tool is running, when the turn actually ended.
///
/// Cost is kept deliberately low. Each watched session holds one file
/// descriptor and one kernel event source; nothing polls. A burst of writes
/// collapses into a single read, and that read only ever looks at the tail of
/// the file, because the only thing worth knowing is what happened last.
@MainActor
final class AgentTranscriptWatcher: ObservableObject {
    static let shared = AgentTranscriptWatcher()

    /// What an agent is doing right now, as told by its own transcript.
    enum Activity: Equatable {
        /// Reasoning before it acts.
        case thinking
        /// Running a tool, named as the agent named it.
        case tool(String)
        /// Mid-turn, nothing more specific to say.
        case working
        /// Stopped, holding, waiting for the user to approve something.
        /// Only the agents that record the asking can report this; for the
        /// rest it still comes from a hook.
        case needsInput
        /// The turn ended. The agent is waiting on the user.
        case idle
    }

    @Published private(set) var activity: [UUID: Activity] = [:]

    /// Identifies the turn that most recently finished, so the sidebar can
    /// tell "finished and you've seen it" from "finished while you were
    /// elsewhere". It changes once per completed turn and never otherwise,
    /// which is the whole contract — the value itself means nothing.
    @Published private(set) var completionToken: [UUID: String] = [:]

    /// Only the last slice of a transcript can describe the present, and
    /// transcripts run to megabytes. Read a window instead of a file.
    private nonisolated static let tailWindow = 48 * 1024

    /// Agents write several lines per step, so an active turn produces a
    /// steady drum of events. Collapsing them keeps the sidebar from
    /// re-rendering per line while still landing well inside a frame.
    private nonisolated static let coalesceInterval: DispatchTimeInterval = .milliseconds(120)

    private let ioQueue = DispatchQueue(
        label: "com.ghostty.agent-transcript",
        qos: .utility
    )

    /// One entry per surface we're following.
    private var watchers: [UUID: Watcher] = [:]

    private final class Watcher {
        let agent: SidebarTabManager.AgentType
        let sessionId: String
        /// The tab's working directory, for the agents joined on it.
        var directory: String?
        var url: URL?
        var source: DispatchSourceFileSystemObject?
        var descriptor: CInt = -1
        var pending: DispatchWorkItem?
        /// Set while a resolve is in flight so we don't stack them up.
        var resolving = false

        init(agent: SidebarTabManager.AgentType, sessionId: String) {
            self.agent = agent
            self.sessionId = sessionId
        }

        func closeSource() {
            pending?.cancel()
            pending = nil
            source?.cancel()
            source = nil
            // The cancel handler owns closing the descriptor.
            descriptor = -1
        }
    }

    private init() {}

    // MARK: - Lifecycle

    /// A surface currently running `agent` under `sessionId`.
    struct Subject {
        let surfaceId: UUID
        let agent: SidebarTabManager.AgentType
        /// Empty for the agents we join on directory instead, because they
        /// never tell us which session a tab is running.
        let sessionId: String
        let directory: String?
    }

    /// Bring the set of watched sessions in line with what the sidebar sees.
    ///
    /// Called on every sidebar rebuild. It is a no-op in the common case where
    /// nothing has started or stopped, so it is cheap to call often.
    func sync(subjects: [Subject]) {
        var wanted: Set<UUID> = []

        for subject in subjects {
            wanted.insert(subject.surfaceId)
            if let existing = watchers[subject.surfaceId] {
                // Same session still running: nothing to do.
                if existing.sessionId == subject.sessionId,
                   existing.agent == subject.agent {
                    existing.directory = subject.directory
                    continue
                }
                // The tab moved to a different session, so the old file is
                // no longer about this tab.
                stop(surfaceId: subject.surfaceId)
            }
            start(subject)
        }

        for surfaceId in watchers.keys where !wanted.contains(surfaceId) {
            stop(surfaceId: surfaceId)
        }
    }

    private func start(_ subject: Subject) {
        let watcher = Watcher(agent: subject.agent, sessionId: subject.sessionId)
        watcher.directory = subject.directory
        watchers[subject.surfaceId] = watcher
        resolve(surfaceId: subject.surfaceId)
    }

    private func stop(surfaceId: UUID) {
        watchers[surfaceId]?.closeSource()
        watchers.removeValue(forKey: surfaceId)
        activity.removeValue(forKey: surfaceId)
    }

    // MARK: - Finding the file

    /// Locate the transcript for a session and start following it.
    ///
    /// A transcript may not exist yet — an agent writes its first line only
    /// after the first prompt — so a miss is expected and simply leaves the
    /// watcher idle until the next sidebar rebuild tries again.
    private func resolve(surfaceId: UUID) {
        guard let watcher = watchers[surfaceId], watcher.url == nil, !watcher.resolving else { return }
        watcher.resolving = true

        let agent = watcher.agent
        let sessionId = watcher.sessionId
        ioQueue.async { [weak self] in
            let found = Self.locateTranscript(agent: agent, sessionId: sessionId)
            Task { @MainActor in
                guard let self,
                      let watcher = self.watchers[surfaceId],
                      watcher.sessionId == sessionId else { return }
                watcher.resolving = false
                guard let found else { return }
                watcher.url = found
                self.attach(surfaceId: surfaceId)
                self.read(surfaceId: surfaceId)
            }
        }
    }

    /// Where each agent keeps the transcript for a given session.
    ///
    /// Only the agents that append one line per event are here. The others
    /// either rewrite a whole JSON document per turn or keep the conversation
    /// in a SQLite database, neither of which can be tailed cheaply, so they
    /// keep using hooks.
    private nonisolated static func locateTranscript(
        agent: SidebarTabManager.AgentType,
        sessionId: String
    ) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default

        switch agent {
        case .claude:
            // ~/.claude/projects/<project slug>/<session>.jsonl. The slug is
            // derived from the working directory, but the session id is
            // already unique, so look for the file rather than rebuild the
            // encoding and risk disagreeing with it.
            let projects = home.appendingPathComponent(".claude/projects", isDirectory: true)
            guard let dirs = try? fm.contentsOfDirectory(
                at: projects,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return nil }
            for dir in dirs {
                let candidate = dir.appendingPathComponent("\(sessionId).jsonl")
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
            return nil

        case .codex:
            // ~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<session>.jsonl.
            // Walk newest day first: a session we care about is a session
            // someone is using right now.
            let sessions = home.appendingPathComponent(".codex/sessions", isDirectory: true)
            let suffix = "-\(sessionId).jsonl"
            guard let walker = fm.enumerator(
                at: sessions,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return nil }
            for case let url as URL in walker {
                if url.lastPathComponent.hasSuffix(suffix) { return url }
            }
            return nil

        case .grok:
            // ~/.grok/sessions/<url-encoded cwd>/<session>/events.jsonl. The
            // directory is keyed by working directory, but the session id is
            // unique, so search for it rather than reproduce the encoding.
            let sessions = home.appendingPathComponent(".grok/sessions", isDirectory: true)
            guard let dirs = try? fm.contentsOfDirectory(
                at: sessions,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return nil }
            for dir in dirs {
                let candidate = dir
                    .appendingPathComponent(sessionId, isDirectory: true)
                    .appendingPathComponent("events.jsonl")
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
            return nil

        case .devin, .cline, .opencode:
            // These keep the conversation in a database rather than a log.
            // Watch its write-ahead journal, which is what actually moves
            // during a session, and fall back to the database file itself
            // when no journal exists yet.
            guard let location = AgentSessionDatabase.location(for: agent) else { return nil }
            if fm.fileExists(atPath: location.journal.path) { return location.journal }
            if fm.fileExists(atPath: location.database.path) { return location.database }
            return nil

        default:
            return nil
        }
    }

    // MARK: - Following the file

    private func attach(surfaceId: UUID) {
        guard let watcher = watchers[surfaceId],
              let url = watcher.url,
              watcher.source == nil else { return }

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: ioQueue
        )
        source.setEventHandler { [weak self] in
            let flags = source.data
            Task { @MainActor in
                guard let self else { return }
                if flags.contains(.delete) || flags.contains(.rename) {
                    // The file we were following is gone. Drop it and let the
                    // next rebuild find whatever replaced it.
                    guard let watcher = self.watchers[surfaceId] else { return }
                    watcher.closeSource()
                    watcher.url = nil
                    return
                }
                self.scheduleRead(surfaceId: surfaceId)
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        watcher.descriptor = fd
        watcher.source = source
        source.resume()
    }

    private func scheduleRead(surfaceId: UUID) {
        guard let watcher = watchers[surfaceId] else { return }
        guard watcher.pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.watchers[surfaceId]?.pending = nil
            self.read(surfaceId: surfaceId)
        }
        watcher.pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceInterval, execute: work)
    }

    private func read(surfaceId: UUID) {
        guard let watcher = watchers[surfaceId], let url = watcher.url else { return }
        let agent = watcher.agent
        let sessionId = watcher.sessionId
        let directory = watcher.directory

        ioQueue.async { [weak self] in
            let reading: Reading?
            switch agent {
            case .devin, .cline, .opencode:
                reading = directory
                    .flatMap { AgentSessionDatabase.activity(agent: agent, directory: $0) }
                    .map { Reading(activity: $0, completedTurn: nil) }
            default:
                reading = Self.deriveActivity(agent: agent, transcript: url)
            }
            let derived = reading?.activity
            Task { @MainActor in
                guard let self,
                      let watcher = self.watchers[surfaceId],
                      watcher.sessionId == sessionId else { return }
                guard let derived else { return }
                if self.activity[surfaceId] != derived {
                    self.activity[surfaceId] = derived
                }
                if let token = reading?.completedTurn,
                   self.completionToken[surfaceId] != token {
                    self.completionToken[surfaceId] = token
                }
            }
        }
    }

    // MARK: - Reading the tail

    /// Read the last window of a transcript and work out what it says about
    /// the present, scanning from the end so we stop at the first line that
    /// settles the question.
    /// One reading of a transcript: what the agent is doing, plus an identity
    /// for the finished turn when the answer is "nothing, it's done".
    struct Reading {
        let activity: Activity
        let completedTurn: String?
    }

    private nonisolated static func deriveActivity(
        agent: SidebarTabManager.AgentType,
        transcript: URL
    ) -> Reading? {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return nil }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(tailWindow) ? end - UInt64(tailWindow) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        // A window that starts mid-file almost certainly starts mid-line.
        if start > 0, !lines.isEmpty { lines.removeFirst() }

        for line in lines.reversed() {
            let object: [String: Any]?
            object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
            guard let entry = object else { continue }
            if let verdict = interpret(agent: agent, entry: entry) { return verdict }
        }
        return nil
    }

    /// Translate one transcript line into an activity, or nil when the line
    /// says nothing about what the agent is doing.
    private nonisolated static func interpret(
        agent: SidebarTabManager.AgentType,
        entry: [String: Any]
    ) -> Reading? {
        switch agent {
        case .claude:
            switch entry["type"] as? String {
            case "assistant":
                guard let message = entry["message"] as? [String: Any] else { return nil }
                // Every line carries its own id, which makes a perfectly good
                // name for the turn it ends.
                let turn = (entry["uuid"] as? String)
                    ?? (entry["timestamp"] as? String)
                let blocks = (message["content"] as? [[String: Any]]) ?? []
                // The last block is what the agent is on right now.
                for block in blocks.reversed() {
                    switch block["type"] as? String {
                    case "tool_use":
                        return .init(
                            activity: .tool((block["name"] as? String) ?? "tool"),
                            completedTurn: nil)
                    case "thinking":
                        return .init(activity: .thinking, completedTurn: nil)
                    default:
                        continue
                    }
                }
                // Plain prose. Whether the turn is over is the stop reason's
                // to say: anything other than a hand-off to a tool ends it.
                if let stop = message["stop_reason"] as? String, stop != "tool_use" {
                    return .init(activity: .idle, completedTurn: turn)
                }
                return .init(activity: .working, completedTurn: nil)

            case "user":
                // Either a fresh prompt or a tool result coming back. Both
                // mean the agent has the ball.
                return .init(activity: .working, completedTurn: nil)

            default:
                // Our own bookkeeping lines and attachments say nothing.
                return nil
            }

        case .codex:
            guard entry["type"] as? String == "event_msg",
                  let payload = entry["payload"] as? [String: Any],
                  let kind = payload["type"] as? String else { return nil }
            switch kind {
            case "task_complete", "turn_aborted":
                // Codex names the turn itself, which is exactly the identity
                // we want for "has the user seen this finish".
                return .init(
                    activity: .idle,
                    completedTurn: (payload["turn_id"] as? String)
                        ?? (entry["timestamp"] as? String))
            case "agent_reasoning":
                return .init(activity: .thinking, completedTurn: nil)
            case "mcp_tool_call_begin", "exec_command_begin", "web_search_begin":
                return .init(activity: .tool(toolName(from: payload)), completedTurn: nil)
            case "task_started", "user_message", "agent_message",
                 "mcp_tool_call_end", "exec_command_end", "patch_apply_begin",
                 "patch_apply_end", "web_search_end":
                return .init(activity: .working, completedTurn: nil)
            default:
                // Token counts and settings churn constantly and mean nothing.
                return nil
            }

        case .grok:
            // Grok keeps the most explicit log of any of them. It names the
            // phase it is in, and it records the asking as well as the answer,
            // so it is the one agent where waiting-for-approval needs no hook.
            switch entry["type"] as? String {
            case "turn_ended":
                return .init(
                    activity: .idle,
                    completedTurn: entry["ts"] as? String)
            case "permission_requested":
                return .init(activity: .needsInput, completedTurn: nil)
            case "permission_resolved", "turn_started", "loop_started", "first_token":
                return .init(activity: .working, completedTurn: nil)
            case "tool_started":
                return .init(
                    activity: .tool((entry["tool_name"] as? String) ?? "tool"),
                    completedTurn: nil)
            case "phase_changed":
                switch entry["phase"] as? String {
                case "streaming_reasoning":
                    return .init(activity: .thinking, completedTurn: nil)
                case "permission_prompt":
                    return .init(activity: .needsInput, completedTurn: nil)
                case "tool_execution":
                    return .init(activity: .tool("tool"), completedTurn: nil)
                case "streaming_text", "waiting_for_model":
                    return .init(activity: .working, completedTurn: nil)
                default:
                    return nil
                }
            default:
                // Its MCP plumbing chatters constantly and means nothing here.
                return nil
            }

        default:
            return nil
        }
    }

    private nonisolated static func toolName(from payload: [String: Any]) -> String {
        if let invocation = payload["invocation"] as? [String: Any],
           let tool = invocation["tool"] as? String { return tool }
        if let tool = payload["tool"] as? String { return tool }
        return "tool"
    }
}
