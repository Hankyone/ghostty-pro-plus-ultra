#!/bin/bash
# ghostty-generate-title.sh — Generate a concise tab title from a user prompt.
# Uses claude -p --bare to skip all project context, hooks, MCP, skills.
# Outputs a clean title string to stdout.
#
# Usage: ghostty-generate-title.sh "user prompt text"
#
# Requires: claude CLI, jq

set -euo pipefail

prompt="${1:-}"
[ -z "$prompt" ] && exit 0

# Truncate to keep the request small
prompt=$(printf '%s' "$prompt" | head -c 500)

# Unset Ghostty IPC so this process doesn't touch the sidebar
unset GHOSTTY_TAB_ID 2>/dev/null || true
unset GHOSTTY_SOCKET 2>/dev/null || true

# Run from /tmp so claude -p doesn't load any project context (CLAUDE.md, etc.)
cd /tmp

response=$(claude -p --no-session-persistence --output-format json --model claude-haiku-4-5 --dangerously-skip-permissions \
  "Return ONLY a JSON object {\"title\":\"...\"} with a 3-8 word title summarizing this coding request. No quotes, no filler, no punctuation. User message: $prompt" 2>/dev/null) || exit 0

[ -z "$response" ] && exit 0

# Extract title from response
title=""
inner=$(echo "$response" | jq -r '.result // empty' 2>/dev/null || echo "")
if [ -n "$inner" ]; then
  title=$(echo "$inner" | jq -r '.title // empty' 2>/dev/null || echo "")
  if [ -z "$title" ]; then
    stripped=$(echo "$inner" | sed 's/^```json//;s/^```//;s/```$//' | tr -d '\n')
    title=$(echo "$stripped" | jq -r '.title // empty' 2>/dev/null || echo "")
  fi
fi
if [ -z "$title" ]; then
  title=$(echo "$response" | jq -r '.title // empty' 2>/dev/null || echo "")
fi

[ -z "$title" ] && exit 0

# Sanitize: first line, strip quotes, collapse whitespace, truncate
title=$(echo "$title" | head -1 | sed 's/^"//;s/"$//' | tr -s ' ' | head -c 50)

[ -z "$title" ] && exit 0
printf '%s' "$title"
