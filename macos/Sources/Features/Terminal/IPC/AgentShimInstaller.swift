import Foundation
import os.log

/// Installs PATH shims that give agent CLIs sidebar hooks with zero user
/// setup — the cmux approach: a wrapper script earlier in PATH intercepts
/// the CLI, injects hook configuration via CLI flags (which merge additively
/// with the user's own settings), and execs the real binary. No user or
/// project config file is ever touched.
///
/// The shim directory is materialized under Application Support at app
/// launch and prepended to PATH by Ghostty's shell integration (via the
/// `GHOSTTY_AGENT_SHIM_DIR` environment variable) so it survives login
/// shells resetting PATH.
///
/// Currently shimmed: `claude` (Claude Code, via `--settings`). The wrapper
/// steps aside automatically when the user already wired ghostty hooks into
/// their own Claude settings, so hooks never fire twice.
enum AgentShimInstaller {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "AgentShim"
    )

    /// The directory containing the shims, or nil if installation failed.
    private(set) static var shimDirectory: String?

    /// Write (or refresh) the shim directory. Idempotent; call at app launch.
    static func install() {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return }
        let bundleId = Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty"
        let dir = appSupport
            .appendingPathComponent(bundleId)
            .appendingPathComponent("agent-shims")

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try write(Self.claudeWrapper, to: dir.appendingPathComponent("claude"), executable: true)
            try write(Self.claudeHookScript, to: dir.appendingPathComponent("ghostty-claude-hook.sh"), executable: true)
            try write(Self.claudeSettingsJSON(hookScript: dir.appendingPathComponent("ghostty-claude-hook.sh").path),
                      to: dir.appendingPathComponent("claude-settings.json"), executable: false)
            shimDirectory = dir.path
            logger.info("agent shims installed at \(dir.path)")
            retireLegacyHooks()
        } catch {
            logger.warning("agent shim install failed: \(error)")
            shimDirectory = nil
        }
    }

    // MARK: - Retiring the old install

    /// Take our hooks back out of the user's global Claude settings.
    ///
    /// Older versions asked people to install hooks into `~/.claude/settings.json`
    /// permanently. That has two problems. It fires in every terminal on the
    /// machine, not just ours, because a hook script has no reliable way to
    /// tell whose terminal it is running in. And it keeps the shim below
    /// dormant, since the shim deliberately stands down when it sees ghostty
    /// hooks already wired up, so the properly scoped path never runs.
    ///
    /// Only entries pointing at our own scripts are removed. Everything else
    /// in the file — other tools' hooks, the status line, settings — is left
    /// exactly as it was, and the original is kept alongside as a backup.
    private static func retireLegacyHooks() {
        let settings = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settings),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any] else { return }

        /// Ours are the scripts we shipped into the user's hooks directory.
        func isOurs(_ command: String) -> Bool {
            command.contains("/.claude/hooks/ghostty-")
        }

        var removed = 0
        for (event, value) in hooks {
            guard var groups = value as? [[String: Any]] else { continue }
            for index in groups.indices {
                guard let entries = groups[index]["hooks"] as? [[String: Any]] else { continue }
                let kept = entries.filter { !isOurs(($0["command"] as? String) ?? "") }
                removed += entries.count - kept.count
                groups[index]["hooks"] = kept
            }
            // A group with nothing left in it, and then an event with no
            // groups left, should go rather than linger as empty scaffolding.
            groups.removeAll { (($0["hooks"] as? [[String: Any]]) ?? []).isEmpty }
            if groups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = groups
            }
        }
        guard removed > 0 else { return }

        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }

        // Keep the original. Rewriting somebody's settings is not the kind of
        // thing that should be one-way, even when it is right.
        let backup = settings.deletingLastPathComponent()
            .appendingPathComponent("settings.json.pre-ghostty-shim")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? data.write(to: backup, options: .atomic)
        }

        guard let updated = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        do {
            try updated.write(to: settings, options: .atomic)
            logger.info("retired \(removed) legacy ghostty hooks from ~/.claude/settings.json")
        } catch {
            logger.warning("could not retire legacy hooks: \(error)")
        }
    }

    private static func write(_ content: String, to url: URL, executable: Bool) throws {
        // Only rewrite when changed so file watchers / mtimes stay quiet.
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == content {
        } else {
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        if executable {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    // MARK: - claude

    /// Wrapper that injects sidebar hooks via `--settings`, which Claude Code
    /// merges additively with the user's own settings (hooks from all
    /// sources run). It steps aside when:
    /// - the real `claude` can't be found,
    /// - the user's own settings already reference ghostty hooks (avoids
    ///   double-firing), or
    /// - there is no live Ghostty IPC socket.
    private static let claudeWrapper = """
    #!/bin/bash
    # Ghostty agent shim — injects sidebar hooks into Claude Code.
    # Generated by Ghostty; edits are overwritten at app launch.
    SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Resolve the real claude binary, skipping every shim, not just our own.
    # Another Ghostty build on PATH installs a shim of its own, and two of them
    # that each only skip themselves will exec each other until the argument
    # list overflows.
    REAL_CLAUDE=""
    IFS=':' read -ra DIRS <<< "$PATH"
    for d in "${DIRS[@]}"; do
      [ "$d" = "$SELF_DIR" ] && continue
      [ -x "$d/claude" ] || continue
      head -n 3 "$d/claude" 2>/dev/null | grep -qs "Ghostty agent shim" && continue
      REAL_CLAUDE="$d/claude"
      break
    done
    [ -z "$REAL_CLAUDE" ] && { echo "claude: command not found" >&2; exit 127; }

    # Step aside if the user's own settings already wire ghostty hooks,
    # if there's no live Ghostty socket, or if jq is unavailable.
    if grep -qs "ghostty" "$HOME/.claude/settings.json" 2>/dev/null \\
       || [ -z "$GHOSTTY_SOCKET" ] || [ ! -S "$GHOSTTY_SOCKET" ] \\
       || ! command -v jq >/dev/null 2>&1; then
      exec "$REAL_CLAUDE" "$@"
    fi

    exec "$REAL_CLAUDE" --settings "$SELF_DIR/claude-settings.json" "$@"
    """

    /// Self-contained hook script speaking the sidebar IPC protocol with nc.
    /// A trimmed version of the user-installable ghostty-sidebar.sh: it keeps
    /// the dot state machine (session/working/needs-input/done) and prompt
    /// label, and leaves fancy extras (LLM tab titles) to user-level hooks.
    private static let claudeHookScript = """
    #!/bin/bash
    # Ghostty agent shim hook — updates sidebar status for Claude Code.
    # Generated by Ghostty; edits are overwritten at app launch.
    set -euo pipefail

    [ -n "${GHOSTTY_SOCKET:-}" ] && [ -S "$GHOSTTY_SOCKET" ] || exit 0
    command -v jq >/dev/null 2>&1 || exit 0

    input=$(cat)
    event=$(echo "$input" | jq -r '.hook_event_name // empty')
    session_id=$(echo "$input" | jq -r '.session_id // empty')

    ipc() { # method key [value]
      local method="$1" key="$2" value="${3:-}"
      local params="\\"key\\": \\"$key\\""
      if [ "$method" = "tab.set-status" ]; then
        value=${value//\\\\/\\\\\\\\}
        value=${value//\\"/\\\\\\"}
        params="$params, \\"value\\": \\"$value\\""
      fi
      if [ -n "${GHOSTTY_TAB_ID:-}" ]; then
        params="\\"tab_id\\": \\"$GHOSTTY_TAB_ID\\", $params"
      fi
      printf '{"method": "%s", "params": {%s}}\\n' "$method" "$params" \\
        | nc -U "$GHOSTTY_SOCKET" >/dev/null 2>&1 || true
    }

    case "$event" in
      SessionStart)
        ipc tab.set-status claude-pid "$PPID"
        ipc tab.set-status claude-session "$session_id"
        ;;
      UserPromptSubmit)
        prompt=$(echo "$input" | jq -r '.prompt // empty' | tr '\\n' ' ' | head -c 120)
        [ -n "$prompt" ] && ipc tab.set-status claude "$prompt"
        # Answering the question is what clears the wait.
        ipc tab.clear-status claude-active
        ;;
      PreToolUse)
        tool_name=$(echo "$input" | jq -r '.tool_name // empty')
        if [ "$tool_name" = "AskUserQuestion" ] || [ "$tool_name" = "ExitPlanMode" ]; then
          ipc tab.set-status claude-active "needs-input"
        else
          ipc tab.clear-status claude-active
        fi
        ;;
      SessionEnd)
        ipc tab.clear-status claude
        ipc tab.clear-status claude-active
        ipc tab.clear-status claude-pid
        ;;
    esac
    """

    private static func claudeSettingsJSON(hookScript: String) -> String {
        // The command is a shell string, and our own path contains a space
        // ("Application Support"), so it has to be quoted or bash reads it as
        // two arguments and runs "/Users/…/Library/Application". Single quotes
        // need no JSON escaping; a literal one inside the path is closed,
        // escaped and reopened the POSIX way.
        let quoted = "'" + hookScript.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let hook = """
        [{"hooks": [{"type": "command", "command": "bash \(quoted)"}]}]
        """
        return """
        {
          "hooks": {
            "SessionStart": \(hook),
            "UserPromptSubmit": \(hook),
            "PreToolUse": \(hook),
            "SessionEnd": \(hook)
          }
        }
        """
    }
}
