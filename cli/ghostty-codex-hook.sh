#!/bin/bash
# ghostty-codex-hook.sh — Codex CLI hook that updates Ghostty sidebar
# with the latest user prompt and activity status for each session.
#
# Hooks: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop
# Requires: jq, ghosttyctl

set -euo pipefail

GHOSTTYCTL="$(dirname "$0")/ghosttyctl"
GENERATE_TITLE="$(dirname "$0")/ghostty-generate-title.sh"
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
TITLED_FILE="$SESSIONS_DIR/$session_id.titled"

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
    "$GHOSTTYCTL" set-status codex-pid "$PPID" 2>/dev/null || true
    "$GHOSTTYCTL" set-status codex-session "$session_id" 2>/dev/null || true

    # Restore a previously generated title for this session (e.g. after resume).
    TITLE_STORE="$SESSIONS_DIR/$session_id.title"
    if [ -f "$TITLE_STORE" ]; then
      saved_title=$(cat "$TITLE_STORE")
      if [ -n "$saved_title" ]; then
        "$GHOSTTYCTL" set-status session-title "$saved_title" --icon "text.bubble" 2>/dev/null || true
      fi
    fi
    ;;

  UserPromptSubmit)
    prompt=$(echo "$input" | jq -r '.prompt // empty')
    [ -z "$prompt" ] && exit 0

    # Mark tab as active (Codex is working)
    "$GHOSTTYCTL" set-status codex-active "working" 2>/dev/null || true

    # Show truncated last prompt as the sidebar label
    short=$(echo "$prompt" | tr '\n' ' ' | head -c 120)
    "$GHOSTTYCTL" set-status codex "$short" --icon "bubble.left.fill" 2>/dev/null || true

    # Generate a tab title on the first prompt only
    if [ ! -f "$TITLED_FILE" ]; then
      touch "$TITLED_FILE"

      # Set an immediate seed title from the prompt text
      seed=$(echo "$prompt" | tr '\n' ' ' | tr -s ' ' | head -c 50)
      "$GHOSTTYCTL" set-status session-title "$seed" --icon "text.bubble" 2>/dev/null || true

      # Launch LLM title generation fully detached so the hook returns immediately.
      TITLE_STORE="$SESSIONS_DIR/$session_id.title"
      nohup bash -c "
        title=\$(\"$GENERATE_TITLE\" \"\$1\" 2>/dev/null || echo \"\")
        if [ -n \"\$title\" ]; then
          \"$GHOSTTYCTL\" set-status session-title \"\$title\" --icon \"text.bubble\" 2>/dev/null || true
          printf '%s' \"\$title\" > \"\$2\"
        fi
      " -- "$prompt" "$TITLE_STORE" </dev/null >/dev/null 2>&1 &
      disown
    fi
    ;;

  PreToolUse)
    # Codex is about to use a tool — ensure status reflects "working"
    "$GHOSTTYCTL" set-status codex-active "working" 2>/dev/null || true
    ;;

  PostToolUse)
    # Tool finished — still working (Codex continues processing)
    "$GHOSTTYCTL" set-status codex-active "working" 2>/dev/null || true
    ;;

  Stop)
    # Codex finished — mark as done and clean up transient state
    "$GHOSTTYCTL" set-status codex-active "done" 2>/dev/null || true

    # Clean up transient metadata (preserve session-title for history)
    "$GHOSTTYCTL" clear-status codex 2>/dev/null || true
    "$GHOSTTYCTL" clear-status codex-active 2>/dev/null || true
    "$GHOSTTYCTL" clear-status codex-pid 2>/dev/null || true
    rm -f "$PID_FILE" "$TAB_ID_FILE"
    ;;
esac
