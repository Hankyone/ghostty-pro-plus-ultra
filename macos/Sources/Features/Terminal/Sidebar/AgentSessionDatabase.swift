import Foundation
import SQLite3

/// Reads agent state out of the SQLite databases some agents keep instead of
/// an append-only transcript.
///
/// Devin and Cline both record the live conversation in a database rather than
/// a log, so they can't be tailed the way Claude's and Codex's transcripts can.
/// They can still be read cheaply: the write-ahead log next to the database
/// changes on every write, which is a perfectly good thing to watch, and the
/// query needed to answer "what is this agent doing" touches one or two rows.
///
/// Everything here is read-only and opened with SQLite's own read-only flag,
/// so we can never be the reason an agent loses a session.
enum AgentSessionDatabase {
    /// Where an agent keeps its live session database, and the file whose
    /// changes mean "something happened".
    struct Location {
        let database: URL
        /// The write-ahead log. It, not the database file, is what moves
        /// during a session, so it is what we put a kernel watch on.
        let journal: URL

        init(database: URL) {
            self.database = database
            self.journal = URL(fileURLWithPath: database.path + "-wal")
        }
    }

    static func location(for agent: SidebarTabManager.AgentType) -> Location? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch agent {
        case .devin:
            return Location(database: home.appendingPathComponent(
                ".local/share/devin/cli/sessions.db"))
        case .cline:
            return Location(database: home.appendingPathComponent(
                ".cline/data/db/sessions.db"))
        default:
            return nil
        }
    }

    /// What the database says the agent is doing in `directory`.
    ///
    /// Neither of these agents hands us a session id, so the working directory
    /// is the join: take the most recently touched session rooted there. Two
    /// tabs in one directory running the same agent will therefore share a
    /// state, which is a real limitation and still far better than the nothing
    /// these two reported before.
    static func activity(
        agent: SidebarTabManager.AgentType,
        directory: String
    ) -> AgentTranscriptWatcher.Activity? {
        guard let location = location(for: agent),
              FileManager.default.fileExists(atPath: location.database.path),
              let handle = open(location.database) else { return nil }
        defer { sqlite3_close(handle) }

        switch agent {
        case .devin:
            return devinActivity(handle, directory: directory)
        case .cline:
            return clineActivity(handle, directory: directory)
        default:
            return nil
        }
    }

    // MARK: - Per agent

    /// Devin records every tool call as a row that gains its completion half
    /// only once the tool returns, so a row still missing that half is a tool
    /// running right now. Failing that, the newest message says whose turn it
    /// is: the agent having spoken last means it is done talking.
    private static func devinActivity(
        _ handle: OpaquePointer,
        directory: String
    ) -> AgentTranscriptWatcher.Activity? {
        guard let session = string(
            handle,
            """
            SELECT id FROM sessions
            WHERE working_directory = ?1
            ORDER BY last_activity_at DESC LIMIT 1
            """,
            directory
        ) else { return nil }

        if let title = string(
            handle,
            """
            SELECT tool_call_json FROM tool_call_state
            WHERE session_id = ?1 AND tool_call_update_json IS NULL
            LIMIT 1
            """,
            session
        ) {
            return .tool(devinToolTitle(title))
        }

        guard let message = string(
            handle,
            """
            SELECT chat_message FROM message_nodes
            WHERE session_id = ?1
            ORDER BY row_id DESC LIMIT 1
            """,
            session
        ) else { return nil }

        guard let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let role = object["role"] as? String else { return nil }
        return role == "assistant" ? .idle : .working
    }

    /// Cline is the simplest of all of them: it keeps a status column, so
    /// there is nothing to infer. We only translate its vocabulary into ours.
    private static func clineActivity(
        _ handle: OpaquePointer,
        directory: String
    ) -> AgentTranscriptWatcher.Activity? {
        guard let status = string(
            handle,
            """
            SELECT status FROM sessions
            WHERE cwd = ?1
            ORDER BY started_at DESC LIMIT 1
            """,
            directory
        ) else { return nil }

        switch status {
        case "running", "busy", "working": return .working
        case "idle", "completed", "failed", "stopped": return .idle
        default: return nil
        }
    }

    private static func devinToolTitle(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "tool" }
        if let title = object["title"] as? String, !title.isEmpty { return title }
        if let kind = object["kind"] as? String, !kind.isEmpty { return kind }
        return "tool"
    }

    // MARK: - Minimal SQLite

    private static func open(_ url: URL) -> OpaquePointer? {
        var handle: OpaquePointer?
        // Read-only, and immutable is deliberately NOT set: the agent is
        // writing, so we do want to see its journal.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        // Never sit behind a writer. A stale answer next tick beats blocking
        // a background read on an agent that is mid-write.
        sqlite3_busy_timeout(handle, 50)
        return handle
    }

    /// Run a one-parameter query and return the first column of the first row.
    private static func string(
        _ handle: OpaquePointer,
        _ sql: String,
        _ parameter: String
    ) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, parameter, -1, transient)

        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: raw)
    }
}
