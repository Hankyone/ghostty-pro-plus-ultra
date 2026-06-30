#!/bin/bash
# ghostty-devin-hook.sh — Devin CLI hook that updates Ghostty sidebar
# with the latest user prompt and activity status for each session.
#
# Devin uses Claude-compatible hook events but does NOT send session_id
# in stdin. We use GHOSTTY_TAB_ID (the surface UUID) as the correlation
# key instead, and store "devin" as a placeholder session marker so the
# sidebar and restore logic can detect Devin tabs.
#
# Hooks: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop, SessionEnd
# Requires: jq, ghosttyctl

set -euo pipefail

GHOSTTYCTL="$(dirname "$0")/ghosttyctl"
SOCKET_PATH="${GHOSTTY_SOCKET:-/tmp/ghostty-$(id -u).sock}"

# Exit early if Ghostty isn't running (no IPC socket)
[ -S "$SOCKET_PATH" ] || exit 0
SESSIONS_DIR="$HOME/Library/Application Support/com.mitchellh.ghostty/devin-sessions"

# Read hook payload from stdin
input=$(cat)
event=$(echo "$input" | jq -r '.hook_event_name // empty')
# Devin doesn't send session_id — use GHOSTTY_TAB_ID as the correlation key
session_id="${GHOSTTY_TAB_ID:-$$}"

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

    # Register Devin's PID for stale session detection.
    echo "$PPID" > "$PID_FILE"
    "$GHOSTTYCTL" set-status devin-pid "$PPID" >/dev/null 2>&1 || true
    # Store a placeholder session marker — Devin doesn't expose session_id in hooks.
    # The restore logic uses "devin" to detect Devin tabs and launches `devin -r`
    # (interactive session picker) instead of resuming a specific session.
    "$GHOSTTYCTL" set-status devin-session "devin" >/dev/null 2>&1 || true
    # Agent is running but idle — show green dot until first prompt
    "$GHOSTTYCTL" set-status devin-active "done" >/dev/null 2>&1 || true
    ;;

  UserPromptSubmit)
    prompt=$(echo "$input" | jq -r '.prompt // empty')
    [ -z "$prompt" ] && exit 0

    # Mark tab as active (Devin is working)
    "$GHOSTTYCTL" set-status devin-active "working" >/dev/null 2>&1 || true

    # Show truncated last prompt as the sidebar label
    short=$(echo "$prompt" | tr '\n' ' ' | head -c 120)
    "$GHOSTTYCTL" set-status devin "$short" --icon "bubble.left.fill" >/dev/null 2>&1 || true
    ;;

  PreToolUse)
    # Devin is about to use a tool — ensure status reflects "working"
    "$GHOSTTYCTL" set-status devin-active "working" >/dev/null 2>&1 || true
    ;;

  PostToolUse)
    # Tool finished — still working (Devin continues processing)
    "$GHOSTTYCTL" set-status devin-active "working" >/dev/null 2>&1 || true
    ;;

  Stop)
    # Devin finished — mark as done (keep devin-active so the green dot persists)
    "$GHOSTTYCTL" set-status devin-active "done" >/dev/null 2>&1 || true
    # Emit a completion token so the sidebar can track unread completions
    "$GHOSTTYCTL" set-status devin-done-at "$(uuidgen)" >/dev/null 2>&1 || true

    # Clean up transient metadata (preserve devin-active)
    "$GHOSTTYCTL" clear-status devin >/dev/null 2>&1 || true
    "$GHOSTTYCTL" clear-status devin-pid >/dev/null 2>&1 || true
    rm -f "$PID_FILE"
    ;;

  SessionEnd)
    # Clear transient status
    "$GHOSTTYCTL" clear-status devin >/dev/null 2>&1 || true
    "$GHOSTTYCTL" clear-status devin-active >/dev/null 2>&1 || true
    "$GHOSTTYCTL" clear-status devin-done-at >/dev/null 2>&1 || true
    "$GHOSTTYCTL" clear-status devin-pid >/dev/null 2>&1 || true
    rm -f "$PID_FILE" "$TAB_ID_FILE"
    ;;
esac
