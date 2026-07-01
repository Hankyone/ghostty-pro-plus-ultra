#!/bin/bash
# ghostty-cursor-hook.sh — Cursor CLI hook that updates Ghostty sidebar
# with the latest user prompt and activity status for each session.
#
# Cursor uses snake_case JSON on stdin with hook_event_name,
# conversation_id (stable session ID), and prompt fields.
# Hooks: sessionStart, beforeSubmitPrompt, preToolUse, postToolUse, stop, sessionEnd
# Requires: jq, ghosttyctl

set -euo pipefail

GHOSTTYCTL="$(dirname "$0")/ghosttyctl"
SOCKET_PATH="${GHOSTTY_SOCKET:-/tmp/ghostty-$(id -u).sock}"

# Exit early if Ghostty isn't running (no IPC socket)
[ -S "$SOCKET_PATH" ] || exit 0
SESSIONS_DIR="$HOME/Library/Application Support/com.mitchellh.ghostty/cursor-sessions"

# Read hook payload from stdin
input=$(cat)
event=$(echo "$input" | jq -r '.hook_event_name // empty')
# Cursor uses conversation_id as the stable session identifier
session_id=$(echo "$input" | jq -r '.conversation_id // .session_id // empty')

mkdir -p "$SESSIONS_DIR"

PID_FILE="$SESSIONS_DIR/$session_id.pid"
TAB_ID_FILE="$SESSIONS_DIR/$session_id.tabid"

# Pin all IPC calls to the tab where this session started.
if [ -f "$TAB_ID_FILE" ]; then
  export GHOSTTY_TAB_ID
  GHOSTTY_TAB_ID=$(cat "$TAB_ID_FILE")
fi

case "$event" in
  sessionStart)
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

    # Register Cursor's PID for stale session detection.
    echo "$PPID" > "$PID_FILE"
    "$GHOSTTYCTL" set-status cursor-pid "$PPID" >/dev/null 2>&1 || true
    "$GHOSTTYCTL" set-status cursor-session "$session_id" >/dev/null 2>&1 || true
    # Agent is running but idle — show green dot until first prompt
    "$GHOSTTYCTL" set-status cursor-active "done" >/dev/null 2>&1 || true
    ;;

  beforeSubmitPrompt)
    prompt=$(echo "$input" | jq -r '.prompt // empty')
    [ -z "$prompt" ] && exit 0

    # Mark tab as active (Cursor is working)
    "$GHOSTTYCTL" set-status cursor-active "working" >/dev/null 2>&1 || true

    # Show truncated last prompt as the sidebar label
    short=$(echo "$prompt" | tr '\n' ' ' | head -c 120)
    "$GHOSTTYCTL" set-status cursor "$short" --icon "bubble.left.fill" >/dev/null 2>&1 || true
    ;;

  preToolUse)
    # Cursor is about to use a tool — ensure status reflects "working"
    "$GHOSTTYCTL" set-status cursor-active "working" >/dev/null 2>&1 || true
    ;;

  postToolUse)
    # Tool finished — still working (Cursor continues processing)
    "$GHOSTTYCTL" set-status cursor-active "working" >/dev/null 2>&1 || true
    ;;

  stop)
    # Cursor finished — mark as done (keep cursor-active so the green dot persists)
    "$GHOSTTYCTL" set-status cursor-active "done" >/dev/null 2>&1 || true
    # Emit a completion token so the sidebar can track unread completions
    "$GHOSTTYCTL" set-status cursor-done-at "$(uuidgen)" >/dev/null 2>&1 || true

    # Clean up transient metadata (preserve cursor-active)
    "$GHOSTTYCTL" clear-status cursor >/dev/null 2>&1 || true
    "$GHOSTTYCTL" clear-status cursor-pid >/dev/null 2>&1 || true
    rm -f "$PID_FILE"
    ;;

  sessionEnd)
    # Clear transient status
    "$GHOSTTYCTL" clear-status cursor >/dev/null 2>&1 || true
    "$GHOSTTYCTL" clear-status cursor-active >/dev/null 2>&1 || true
    "$GHOSTTYCTL" clear-status cursor-done-at >/dev/null 2>&1 || true
    "$GHOSTTYCTL" clear-status cursor-pid >/dev/null 2>&1 || true
    rm -f "$PID_FILE" "$TAB_ID_FILE"
    ;;
esac
