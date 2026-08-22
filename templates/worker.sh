#!/bin/bash
# Template: queue worker that runs Claude headless with hard guardrails.
#
# The pattern: other agents (monitors, webhooks, you) drop a .job file into
# queue/. This worker runs on cron, takes ONE job per run, gives Claude
# read-only access to a local repo checkout, and sends the diagnosis to
# Telegram. It never edits code, never opens PRs, never touches anything.
#
# Guardrails, each one paid for by a real incident somewhere:
#   - flock: one worker at a time (parallel LLM runs can OOM a small VPS).
#   - MIN_RAM_MB: defer the job if the box is low on memory.
#   - DAILY_CAP: hard ceiling on LLM runs per day, so a flapping monitor
#     cannot turn into a surprise API bill.
#   - timeout: hard per-run limit; a hung CLI call must not wedge the queue.
#   - Read-only tool allowlist + explicit disallow of write tools. If you
#     want an agent that edits code, do it behind a PR that a human merges.
#
# Job file format (plain text, one file per job in queue/*.job):
#   repo: /absolute/path/to/local/checkout
#   prefix: [MYAPP]
#   ---
#   <free text: the alert or question for the model>
#
# Modes:
#   worker.sh            normal run (cron)
#   worker.sh --status   show queue state and exit
#
# Cron example (every 5 min, offset to run after your monitors):
#   2-59/5 * * * * /bin/bash $HOME/agents/ai-worker/worker.sh

set -uo pipefail

AGENTS_HOME="${AGENTS_HOME:-$HOME/agents}"
source "$AGENTS_HOME/shared/env.sh"
export HOME="${HOME:?}"

AGENT="$(basename "$(cd "$(dirname "$0")" && pwd)")"
DIR="$AGENTS_HOME/$AGENT"
QUEUE="$DIR/queue"
STATE="$DIR/state"
NOTIFY="$AGENTS_HOME/shared/notify.sh"
LOGGER="$AGENTS_HOME/shared/log.sh"

DAILY_CAP="${DAILY_CAP:-8}"               # max LLM runs per day (UTC)
MIN_RAM_MB="${MIN_RAM_MB:-1500}"          # defer below this much available RAM
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-900}"   # hard cap per analysis, seconds
CLAUDE_MODEL="${CLAUDE_MODEL:-sonnet}"
MAX_TG_CHARS=3500                         # stay under Telegram's 4096 limit

mkdir -p "$QUEUE" "$STATE" "$DIR/done" "$DIR/failed" "$DIR/logs"
log() { bash "$LOGGER" "$AGENT" "$*"; }

if [ "${1:-}" = "--status" ]; then
    echo "queue:  $(ls -1 "$QUEUE" 2>/dev/null | wc -l) job(s)"
    echo "today:  $(cat "$STATE/count-$(date -u +%F)" 2>/dev/null || echo 0)/$DAILY_CAP runs"
    exit 0
fi

# ---------------- global lock: one worker at a time ----------------
exec 9>"$STATE/lock"
flock -n 9 || exit 0

# ---------------- any work? ----------------
job=$(ls -1 "$QUEUE"/*.job 2>/dev/null | sort | head -1 || true)
[ -z "${job:-}" ] && exit 0

# ---------------- resource guardrails ----------------
avail_mb=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
if [ "$avail_mb" -lt "$MIN_RAM_MB" ]; then
    log "low RAM (${avail_mb}MB < ${MIN_RAM_MB}MB), deferring $(basename "$job")"
    exit 0
fi

today=$(date -u +%F)
countfile="$STATE/count-$today"
count=$(cat "$countfile" 2>/dev/null || echo 0)
if [ "$count" -ge "$DAILY_CAP" ]; then
    log "daily cap reached ($count/$DAILY_CAP); $(ls -1 "$QUEUE" | wc -l) job(s) wait for tomorrow"
    exit 0
fi

# ---------------- parse job ----------------
repo=$(sed -n 's/^repo: //p' "$job" | head -1)
prefix=$(sed -n 's/^prefix: //p' "$job" | head -1)
task=$(sed -n '/^---$/,$p' "$job" | tail -n +2)

if [ ! -d "${repo:-/nonexistent}" ]; then
    log "invalid job $(basename "$job") (repo='$repo'), discarding"
    mv "$job" "$DIR/failed/$(basename "$job")"
    exit 1
fi

echo $((count + 1)) > "$countfile"

# Refresh the checkout before diagnosing: a stale repo makes the model conclude
# the bug "does not exist in the code" when it is freshly deployed code.
# Best effort: if the pull fails (offline, dirty tree), diagnose what is there.
git -C "$repo" pull --ff-only -q 2>/dev/null || log "warning: git pull failed in $repo (using current checkout)"

mv "$job" "$job.processing"
log "run #$((count + 1))/$DAILY_CAP today: $(basename "$job")"

# ---------------- prompt ----------------
prompt="You are an unattended triage agent. A monitoring system produced this alert or task:

--- TASK ---
$task
--- END TASK ---

The local checkout of the relevant repo is at: $repo
You may explore it to understand the code, with these rules:
- You are READ-ONLY. Do not edit, create files, or run anything that mutates state.
- The checkout may be on a different branch than what is deployed; if it matters, use 'git log' or 'git show origin/main:<file>' and assume deployed code may lag slightly.
- Never suggest automated actions on payment or money flows; flag them for a human.

Your job: diagnose and classify. Reply ONLY with the final text for a chat message (no preamble), at most 1200 characters, plain text (no markdown headers, no code blocks, no decorative asterisks or underscores), with exactly this structure and ONE BLANK LINE between fields:

Classification: [OUR BUG | EXTERNAL FAILURE | CONFIG/OPERATIONS | UNKNOWN]

Severity: [high | medium | low]

What happened: <1-3 sentences>

Likely cause: <1-3 sentences, with file:line if you found it>

Recommended action: <1-2 concrete sentences; 'none' if it is noise or already resolved>

If the error appears to come from an external provider rejecting our request, still check whether OUR payload is the problem before classifying it as external."

# ---------------- run claude headless (read-only) ----------------
diag=$(cd "$repo" && timeout "$CLAUDE_TIMEOUT" nice -n 10 claude -p "$prompt" \
    --model "$CLAUDE_MODEL" \
    --allowedTools "Read,Glob,Grep,Bash(git log:*),Bash(git show:*),Bash(git diff:*),Bash(git blame:*),Bash(grep:*),Bash(rg:*),Bash(ls:*),Bash(cat:*),Bash(head:*),Bash(tail:*)" \
    --disallowedTools "Edit,Write,NotebookEdit,WebFetch,WebSearch,Task" \
    2>>"$DIR/logs/claude-stderr.log")
rc=$?

if [ "$rc" -ne 0 ] || [ -z "$diag" ]; then
    log "claude failed (rc=$rc) for $(basename "$job")"
    mv "$job.processing" "$DIR/failed/$(basename "$job")"
    exit 1
fi

# ---------------- send diagnosis ----------------
# Escape _ * [ ` in generated content so Telegram's Markdown mode does not
# swallow those characters (paths, field names, identifiers).
diag_short=$(printf '%s' "$diag" | head -c "$MAX_TG_CHARS" | sed 's/[_*`[]/\\&/g')
bash "$NOTIFY" "$prefix *Automated triage*

$diag_short

_diagnosis only; nothing was modified_" >/dev/null 2>&1 \
    && log "diagnosis sent for $(basename "$job")" \
    || log "notify failed for $(basename "$job")"

mv "$job.processing" "$DIR/done/$(basename "$job")"
printf '%s\n' "$diag" > "$DIR/done/$(basename "$job").diag"

# Keep only the last 50 processed jobs.
ls -1t "$DIR/done" 2>/dev/null | tail -n +51 | while read -r f; do rm -f "$DIR/done/$f"; done
ls -1t "$DIR/failed" 2>/dev/null | tail -n +51 | while read -r f; do rm -f "$DIR/failed/$f"; done
exit 0
