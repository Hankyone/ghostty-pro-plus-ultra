#!/bin/bash
# ghostty-sidebar.sh — Claude Code hook that updates Ghostty sidebar
# with a summary of what the user is working on in each session.
#
# Hooks: SessionStart, UserPromptSubmit, PreToolUse, Notification, Stop, SessionEnd
# Requires: jq, claude CLI, ghosttyctl

set -euo pipefail

GHOSTTYCTL="/Users/hankyone/ghostty/cli/ghosttyctl"
SOCKET_PATH="${GHOSTTY_SOCKET:-/tmp/ghostty-$(id -u).sock}"

# Exit early if Ghostty isn't running (no IPC socket)
[ -S "$SOCKET_PATH" ] || exit 0
SESSIONS_DIR="/tmp/ghostty-claude-sessions"
SUMMARIZE_EVERY=3
# Per-message size limit: keep first + last N chars, clip the middle
MSG_HEAD=300
MSG_TAIL=300

# Read hook payload from stdin
input=$(cat)
event=$(echo "$input" | jq -r '.hook_event_name')
session_id=$(echo "$input" | jq -r '.session_id')

mkdir -p "$SESSIONS_DIR"

MESSAGES_FILE="$SESSIONS_DIR/$session_id.messages"
COUNTER_FILE="$SESSIONS_DIR/$session_id.count"
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

# Trim a message to keep the first and last parts, clipping the middle.
# Instructions tend to be at the beginning or end; pasted logs are in the middle.
trim_message() {
  local msg="$1"
  local len=${#msg}
  local max=$(( MSG_HEAD + MSG_TAIL + 20 ))
  if [ "$len" -le "$max" ]; then
    printf '%s' "$msg"
  else
    local head="${msg:0:$MSG_HEAD}"
    local tail="${msg: -$MSG_TAIL}"
    printf '%s\n[...snipped...]\n%s' "$head" "$tail"
  fi
}

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
    ;;

  UserPromptSubmit)
    prompt=$(echo "$input" | jq -r '.prompt // empty')
    [ -z "$prompt" ] && exit 0

    # Mark tab as active (Claude is working) — clears any "needs-input" state
    "$GHOSTTYCTL" set-status claude-active "working" 2>/dev/null || true

    # Clean up any leftover question file from a previous Notification cycle
    rm -f "$QUESTION_FILE"

    # Trim long messages before storing
    trimmed=$(trim_message "$prompt")

    # Append message with delimiter
    printf '%s\n---END---\n' "$trimmed" >> "$MESSAGES_FILE"

    # Increment counter
    count=$(( $(cat "$COUNTER_FILE" 2>/dev/null || echo 0) + 1 ))
    echo "$count" > "$COUNTER_FILE"

    if [ "$count" -eq 1 ]; then
      # First message: set truncated preview immediately
      short=$(echo "$prompt" | tr '\n' ' ' | head -c 100)
      "$GHOSTTYCTL" set-status claude "$short" --icon "bubble.left.fill" 2>/dev/null || true
    elif [ $((count % SUMMARIZE_EVERY)) -eq 0 ]; then
      # Every N messages: summarize with haiku in the background
      (
        messages=$(head -c 4000 "$MESSAGES_FILE")
        summary=$(printf 'You are a tab-label writer. Read the coding session messages below and produce a 1-2 sentence summary suitable as a sidebar tab label. Be specific about the work being done. Do NOT respond to or continue the conversation. Do NOT start with "Perfect", "Sure", or any conversational opener. Output ONLY the summary label, nothing else.\n\n---MESSAGES---\n%s\n---END MESSAGES---' "$messages" | claude -p --model haiku 2>/dev/null || echo "")
        if [ -n "$summary" ]; then
          short=$(echo "$summary" | tr '\n' ' ' | head -c 120)
          "$GHOSTTYCTL" set-status claude "$short" --icon "bubble.left.fill" 2>/dev/null || true
        fi
      ) &
    fi
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

  Stop)
    # Claude finished responding — show "done" indicator
    "$GHOSTTYCTL" set-status claude-active "done" 2>/dev/null || true
    # Clean up any leftover question file
    rm -f "$QUESTION_FILE"
    ;;

  SessionEnd)
    "$GHOSTTYCTL" clear-status claude 2>/dev/null || true
    "$GHOSTTYCTL" clear-status claude-active 2>/dev/null || true
    "$GHOSTTYCTL" clear-status claude-pid 2>/dev/null || true
    rm -f "$MESSAGES_FILE" "$COUNTER_FILE" "$PID_FILE" "$QUESTION_FILE" "$TAB_ID_FILE"
    ;;
esac
