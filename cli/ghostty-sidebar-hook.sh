#!/bin/bash
# ghostty-sidebar.sh — Claude Code hook that updates Ghostty sidebar
# with the latest user prompt and activity status for each session.
#
# Hooks: SessionStart, UserPromptSubmit, PreToolUse, Notification, Stop, StopFailure, SessionEnd
# Requires: jq, ghosttyctl

set -euo pipefail

GHOSTTYCTL="$(dirname "$0")/ghosttyctl"
SOCKET_PATH="${GHOSTTY_SOCKET:-/tmp/ghostty-$(id -u).sock}"

# Exit early if Ghostty isn't running (no IPC socket)
[ -S "$SOCKET_PATH" ] || exit 0
SESSIONS_DIR="$HOME/Library/Application Support/com.mitchellh.ghostty/claude-sessions"

# Read hook payload from stdin
input=$(cat)
event=$(echo "$input" | jq -r '.hook_event_name')
session_id=$(echo "$input" | jq -r '.session_id')

mkdir -p "$SESSIONS_DIR"

PID_FILE="$SESSIONS_DIR/$session_id.pid"
QUESTION_FILE="$SESSIONS_DIR/$session_id.question"
TAB_ID_FILE="$SESSIONS_DIR/$session_id.tabid"

# Pin all IPC calls to the tab where this session started.
# Without this, ghosttyctl falls back to NSApp.keyWindow which can be
# wrong if the user switches apps or focus shifts momentarily.
if [ -f "$TAB_ID_FILE" ]; then
  export GHOSTTY_TAB_ID
  GHOSTTY_TAB_ID=$(cat "$TAB_ID_FILE")
fi

case "$event" in
  SessionStart)
    # Capture the tab/surface UUID so all future IPC calls target the right tab,
    # even if the user switches focus away from Ghostty.
    # Prefer the GHOSTTY_TAB_ID env var (set by Ghostty for this terminal) over
    # an IPC call, which can fail if the window isn't key or another Ghostty
    # instance has replaced the socket.
    tab_id="${GHOSTTY_TAB_ID:-}"
    if [ -z "$tab_id" ]; then
      tab_json=$("$GHOSTTYCTL" current 2>/dev/null || echo "")
      tab_id=$(echo "$tab_json" | jq -r '.tab_id // empty' 2>/dev/null || echo "")
    fi
    if [ -n "$tab_id" ]; then
      echo "$tab_id" > "$TAB_ID_FILE"
      export GHOSTTY_TAB_ID="$tab_id"
    fi

    # Register Claude's PID for stale session detection.
    # $PPID is the Claude Code process that spawned this hook.
    echo "$PPID" > "$PID_FILE"
    "$GHOSTTYCTL" set-status claude-pid "$PPID" 2>/dev/null || true
    "$GHOSTTYCTL" set-status claude-session "$session_id" 2>/dev/null || true
    # Agent is running but idle — show green dot until first prompt
    "$GHOSTTYCTL" set-status claude-active "done" 2>/dev/null || true
    ;;

  UserPromptSubmit)
    prompt=$(echo "$input" | jq -r '.prompt // empty')
    [ -z "$prompt" ] && exit 0

    # Mark tab as active (Claude is working) — clears any "needs-input" state
    "$GHOSTTYCTL" set-status claude-active "working" 2>/dev/null || true

    # Clean up any leftover question file from a previous Notification cycle
    rm -f "$QUESTION_FILE"

    # Show truncated last prompt as the sidebar label
    short=$(echo "$prompt" | tr '\n' ' ' | head -c 120)
    "$GHOSTTYCTL" set-status claude "$short" --icon "bubble.left.fill" 2>/dev/null || true
    ;;

  PreToolUse)
    tool_name=$(echo "$input" | jq -r '.tool_name // empty')

    if [ "$tool_name" = "AskUserQuestion" ]; then
      # Claude is asking the user a question — set needs-input
      "$GHOSTTYCTL" set-status claude-active "needs-input" 2>/dev/null || true
      question=$(echo "$input" | jq -r '.tool_input.question // empty')
      if [ -n "$question" ]; then
        echo "$question" > "$QUESTION_FILE"
      fi
    elif [ "$tool_name" = "ExitPlanMode" ]; then
      # Claude is presenting a plan for approval — set needs-input
      "$GHOSTTYCTL" set-status claude-active "needs-input" 2>/dev/null || true
    else
      # Claude is actively working — ensure status reflects "working"
      "$GHOSTTYCTL" set-status claude-active "working" 2>/dev/null || true
    fi
    ;;

  Notification)
    # Send desktop notification only — don't change claude-active status.
    # The activity state is managed by PreToolUse (working/needs-input) and Stop (done).
    message=""
    if [ -f "$QUESTION_FILE" ]; then
      message=$(cat "$QUESTION_FILE")
      rm -f "$QUESTION_FILE"
    else
      message=$(echo "$input" | jq -r '.message // empty')
    fi

    if [ -n "$message" ]; then
      short=$(echo "$message" | tr '\n' ' ' | head -c 200)
      "$GHOSTTYCTL" notify --title "Claude needs input" --body "$short" 2>/dev/null || true
    fi
    ;;

  Stop|StopFailure)
    # Claude finished responding (or hit an API error) — show "done" indicator
    "$GHOSTTYCTL" set-status claude-active "done" 2>/dev/null || true
    # Emit a completion token so the sidebar can track unread completions
    "$GHOSTTYCTL" set-status claude-done-at "$(uuidgen)" 2>/dev/null || true
    # Clean up any leftover question file
    rm -f "$QUESTION_FILE"
    ;;

  SessionEnd)
    # Clear transient status
    "$GHOSTTYCTL" clear-status claude 2>/dev/null || true
    "$GHOSTTYCTL" clear-status claude-active 2>/dev/null || true
    "$GHOSTTYCTL" clear-status claude-done-at 2>/dev/null || true
    "$GHOSTTYCTL" clear-status claude-pid 2>/dev/null || true
    rm -f "$PID_FILE" "$QUESTION_FILE" "$TAB_ID_FILE"
    ;;
esac
