#!/bin/bash
# ghostty-grok-hook.sh — Grok CLI hook that updates Ghostty sidebar
# with the latest user prompt and activity status for each session.
#
# Grok sends camelCase JSON on stdin (hookEventName, sessionId, toolName,
# toolInput) and sets GROK_SESSION_ID / GROK_WORKSPACE_ROOT env vars.
#
# Hooks: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop, StopFailure, SessionEnd
# Requires: jq, ghosttyctl

set -euo pipefail

GHOSTTYCTL="$(dirname "$0")/ghosttyctl"
SOCKET_PATH="${GHOSTTY_SOCKET:-/tmp/ghostty-$(id -u).sock}"

# Exit early if Ghostty isn't running (no IPC socket)
[ -S "$SOCKET_PATH" ] || exit 0
SESSIONS_DIR="$HOME/Library/Application Support/com.mitchellh.ghostty/grok-sessions"

# Read hook payload from stdin
input=$(cat)
# Grok uses camelCase field names
event=$(echo "$input" | jq -r '.hookEventName // .hook_event_name // empty')
# Prefer GROK_SESSION_ID env var, fall back to stdin sessionId
session_id="${GROK_SESSION_ID:-$(echo "$input" | jq -r '.sessionId // .session_id // empty')}"

mkdir -p "$SESSIONS_DIR"

PID_FILE="$SESSIONS_DIR/$session_id.pid"
TAB_ID_FILE="$SESSIONS_DIR/$session_id.tabid"

# Pin all IPC calls to the tab where this session started.
if [ -f "$TAB_ID_FILE" ]; then
  export GHOSTTY_TAB_ID
  GHOSTTY_TAB_ID=$(cat "$TAB_ID_FILE")
fi

case "$event" in
  session_start|SessionStart)
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

    # Register Grok's PID for stale session detection.
    echo "$PPID" > "$PID_FILE"
    "$GHOSTTYCTL" set-status grok-pid "$PPID" >/dev/null 2>&1 || true
    "$GHOSTTYCTL" set-status grok-session "$session_id" >/dev/null 2>&1 || true
    # Agent is running but idle — show green dot until first prompt
    "$GHOSTTYCTL" set-status grok-active "done" >/dev/null 2>&1 || true
    ;;

  user_prompt_submit|UserPromptSubmit)
    prompt=$(echo "$input" | jq -r '.prompt // empty')
    [ -z "$prompt" ] && exit 0

    # Mark tab as active (Grok is working)
    "$GHOSTTYCTL" set-status grok-active "working" >/dev/null 2>&1 || true

    # Show truncated last prompt as the sidebar label
    short=$(echo "$prompt" | tr '\n' ' ' | head -c 120)
    "$GHOSTTYCTL" set-status grok "$short" --icon "bubble.left.fill" >/dev/null 2>&1 || true
    ;;

  pre_tool_use|PreToolUse)
    # Grok is about to use a tool — ensure status reflects "working"
    "$GHOSTTYCTL" set-status grok-active "working" >/dev/null 2>&1 || true
    ;;

  post_tool_use|PostToolUse)
    # Tool finished — still working (Grok continues processing)
    "$GHOSTTYCTL" set-status grok-active "working" >/dev/null 2>&1 || true
    ;;

  stop|Stop|stop_failure|StopFailure)
    # Grok finished — mark as done (keep grok-active so the green dot persists)
    "$GHOSTTYCTL" set-status grok-active "done" >/dev/null 2>&1 || true
    # Emit a completion token so the sidebar can track unread completions
    "$GHOSTTYCTL" set-status grok-done-at "$(uuidgen)" >/dev/null 2>&1 || true

    # Clean up transient metadata (preserve grok-active)
    "$GHOSTTYCTL" clear-status grok >/dev/null 2>&1 || true
    "$GHOSTTYCTL" clear-status grok-pid >/dev/null 2>&1 || true
    rm -f "$PID_FILE"
    ;;

  session_end|SessionEnd)
    # Clear transient status
    "$GHOSTTYCTL" clear-status grok >/dev/null 2>&1 || true
    "$GHOSTTYCTL" clear-status grok-active >/dev/null 2>&1 || true
    "$GHOSTTYCTL" clear-status grok-done-at >/dev/null 2>&1 || true
    "$GHOSTTYCTL" clear-status grok-pid >/dev/null 2>&1 || true
    rm -f "$PID_FILE" "$TAB_ID_FILE"
    ;;
esac
