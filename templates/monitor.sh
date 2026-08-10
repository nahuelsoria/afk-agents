#!/bin/bash
# Template: alert-only monitor. Silence means OK.
#
# Copy this folder, rename it, and fill in the CHECK block. The skeleton
# handles the parts people get wrong: cron-safe environment, per-run logging,
# and alert deduping so a persistent failure does not page you every 5 minutes.
#
# Cron example (every 30 min):
#   */30 * * * * /bin/bash $HOME/agents/my-monitor/run.sh

set -uo pipefail

AGENTS_HOME="${AGENTS_HOME:-$HOME/agents}"
source "$AGENTS_HOME/shared/env.sh"

AGENT="$(basename "$(cd "$(dirname "$0")" && pwd)")"
DIR="$AGENTS_HOME/$AGENT"
STATE="$DIR/state"
NOTIFY="$AGENTS_HOME/shared/notify.sh"
LOGGER="$AGENTS_HOME/shared/log.sh"
mkdir -p "$STATE"

# Re-alert at most every N hours while the problem persists. Recovery clears it.
REALERT_HOURS="${REALERT_HOURS:-6}"

log() { bash "$LOGGER" "$AGENT" "$*"; }

# alert "<message>": send to Telegram unless the same condition alerted recently.
alert() {
    local marker="$STATE/alerted"
    if [ -f "$marker" ] && [ -n "$(find "$marker" -mmin "-$((REALERT_HOURS * 60))" 2>/dev/null)" ]; then
        log "still failing, alert suppressed (last one under ${REALERT_HOURS}h ago)"
        return 0
    fi
    bash "$NOTIFY" "$1" && touch "$marker"
    log "alert sent"
}

# recovered: clear the dedup marker and optionally announce the recovery.
recovered() {
    if [ -f "$STATE/alerted" ]; then
        rm -f "$STATE/alerted"
        bash "$NOTIFY" "$1"
        log "recovery sent"
    fi
}

# ---------------- CHECK: replace this block ----------------
# Example: alert when root disk usage crosses a threshold.
THRESHOLD="${THRESHOLD:-90}"
usage=$(df -P / | awk 'NR==2 {gsub("%",""); print $5}')

if [ "$usage" -ge "$THRESHOLD" ]; then
    alert "*disk-watch* root disk at ${usage}% (threshold ${THRESHOLD}%)"
else
    recovered "*disk-watch* recovered: root disk back to ${usage}%"
    log "ok (${usage}%)"
fi
# ---------------- END CHECK ----------------
