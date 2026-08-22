#!/bin/bash
# Template: scheduled LLM digest that survives being re-read weeks later.
#
# The pattern: on a schedule (weekly is the sweet spot), gather context from
# your own sources, ask Claude for a short synthesis, ARCHIVE it to disk with
# keep_output, then send it to Telegram. The archive step is the point: chat
# messages cannot be re-read by your tools later, files can.
#
# Fill in the GATHER block with your own sources: git logs across repos,
# metrics endpoints, task files, RSS output, whatever you want summarized.
#
# Cron example (Sunday 19:00 server time):
#   0 19 * * 0 /bin/bash $HOME/agents/weekly-digest/digest.sh

set -uo pipefail

AGENTS_HOME="${AGENTS_HOME:-$HOME/agents}"
source "$AGENTS_HOME/shared/env.sh"
source "$AGENTS_HOME/shared/keep.sh"

AGENT="$(basename "$(cd "$(dirname "$0")" && pwd)")"
DIR="$AGENTS_HOME/$AGENT"
NOTIFY="$AGENTS_HOME/shared/notify.sh"
LOGGER="$AGENTS_HOME/shared/log.sh"
mkdir -p "$DIR/state" "$DIR/logs"

CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-600}"
CLAUDE_MODEL="${CLAUDE_MODEL:-sonnet}"

log() { bash "$LOGGER" "$AGENT" "$*"; }

# ---------------- GATHER: replace this block ----------------
# Build $context from your own sources. Example: last week of commits across
# every repo under ~/code, so the digest reports what actually shipped.
context=""
for repo in "$HOME"/code/*/.git; do
    d="$(dirname "$repo")"
    recent=$(git -C "$d" log --oneline --since="7 days ago" 2>/dev/null | head -20)
    [ -n "$recent" ] && context+="## $(basename "$d")
$recent

"
done
[ -z "$context" ] && { log "nothing to digest this week"; exit 0; }
# ---------------- END GATHER ----------------

prompt="You are a weekly review assistant. Below is raw activity from the last 7 days.

$context

Write a digest for a chat message, at most 2500 characters, plain text with simple lists (no markdown headers, no code blocks). Structure:

1. What moved this week (3-6 bullets, most important first)
2. What looks stalled or risky (only if the data shows it)
3. One suggestion for next week

Be concrete: name the project. Do not pad; if a section has nothing, skip it."

digest=$(timeout "$CLAUDE_TIMEOUT" claude -p "$prompt" \
    --model "$CLAUDE_MODEL" \
    --allowedTools "" \
    2>>"$DIR/logs/claude-stderr.log")
rc=$?

if [ "$rc" -ne 0 ] || [ -z "$digest" ]; then
    log "claude failed (rc=$rc), no digest this week"
    bash "$NOTIFY" "weekly-digest: generation failed (rc=$rc), check logs"
    exit 1
fi

# Archive BEFORE sending: if notify fails, the content still exists on disk.
keep_output "$DIR" digest "$digest" || log "warning: could not archive digest"

esc=$(printf '%s' "$digest" | sed 's/[_*`[]/\\&/g')
bash "$NOTIFY" "*Weekly digest*

$esc" && log "digest sent and archived" || { log "notify failed"; exit 1; }
