#!/bin/bash
# ghostty-codex-hook.sh — Codex CLI hook that updates Ghostty sidebar
# with the latest user prompt and activity status for each session.
#
# Hooks: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop
# Requires: jq, ghosttyctl
#
# IMPORTANT: Codex parses hook stdout as JSON. Any stray output causes
# "invalid … JSON output" errors, so all ghosttyctl calls redirect
# stdout+stderr to /dev/null. Exit 0 with no output = success.

set -euo pipefail

GHOSTTYCTL="$(dirname "$0")/ghosttyctl"
SOCKET_PATH="${GHOSTTY_SOCKET:-/tmp/ghostty-$(id -u).sock}"

# Exit early if Ghostty isn't running (no IPC socket)
[ -S "$SOCKET_PATH" ] || exit 0
SESSIONS_DIR="$HOME/Library/Application Support/com.mitchellh.ghostty/codex-sessions"

# Read hook payload from stdin
input=$(cat)
event=$(echo "$input" | jq -r '.hook_event_name')
session_id=$(echo "$input" | jq -r '.session_id')

mkdir -p "$SESSIONS_DIR"

PID_FILE="$SESSIONS_DIR/$session_id.pid"
TAB_ID_FILE="$SESSIONS_DIR/$session_id.tabid"

# Pin all IPC calls to the tab where this session started.
if [ -f "$TAB_ID_FILE" ]; then
  export GHOSTTY_TAB_ID
  GHOSTTY_TAB_ID=$(cat "$TAB_ID_FILE")
fi

case "$event" in
  SessionStart)
    # Capture the tab/surface UUID so all future IPC calls target the right tab.
    tab_id="${GHOSTTY_TAB_ID:-}"
    if [ -z "$tab_id" ]; then
      tab_json=$("$GHOSTTYCTL" current 2>/dev/null || echo "")
      tab_id=$(echo "$tab_json" | jq -r '.tab_id // empty' 2>/dev/null || echo "")
    fi
    if [ -n "$tab_id" ]; then
      echo "$tab_id" > "$TAB_ID_FILE"
      export GHOSTTY_TAB_ID="$tab_id"
    fi

    # Register Codex's PID for stale session detection.
    echo "$PPID" > "$PID_FILE"
    "$GHOSTTYCTL" set-status codex-pid "$PPID" >/dev/null 2>&1 || true
    "$GHOSTTYCTL" set-status codex-session "$session_id" >/dev/null 2>&1 || true
    # Agent is running but idle — show green dot until first prompt
    "$GHOSTTYCTL" set-status codex-active "done" >/dev/null 2>&1 || true
    ;;

  UserPromptSubmit)
    prompt=$(echo "$input" | jq -r '.prompt // empty')
    [ -z "$prompt" ] && exit 0

    # Mark tab as active (Codex is working)
    "$GHOSTTYCTL" set-status codex-active "working" >/dev/null 2>&1 || true

    # Show truncated last prompt as the sidebar label
    short=$(echo "$prompt" | tr '\n' ' ' | head -c 120)
    "$GHOSTTYCTL" set-status codex "$short" --icon "bubble.left.fill" >/dev/null 2>&1 || true
    ;;

  PreToolUse)
    # Codex is about to use a tool — ensure status reflects "working"
    "$GHOSTTYCTL" set-status codex-active "working" >/dev/null 2>&1 || true
    ;;

  PostToolUse)
    # Tool finished — still working (Codex continues processing)
    "$GHOSTTYCTL" set-status codex-active "working" >/dev/null 2>&1 || true
    ;;

  Stop)
    # Codex finished — mark as done (keep codex-active so the green dot persists)
    "$GHOSTTYCTL" set-status codex-active "done" >/dev/null 2>&1 || true
    # Emit a completion token so the sidebar can track unread completions
    "$GHOSTTYCTL" set-status codex-done-at "$(uuidgen)" >/dev/null 2>&1 || true

    # Clean up transient metadata (preserve codex-active)
    "$GHOSTTYCTL" clear-status codex >/dev/null 2>&1 || true
    "$GHOSTTYCTL" clear-status codex-pid >/dev/null 2>&1 || true
    rm -f "$PID_FILE"
    ;;
esac
