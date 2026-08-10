#!/bin/bash
# Smoke test: exercises the CLI end to end against a throwaway AGENTS_HOME and a
# fake crontab, so it never touches the real fleet or the user's real crontab.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export AGENTS_HOME="$TMP/agents"

# Fake crontab: reads/writes a file instead of the user's real crontab.
FAKECRON="$TMP/fakecron"
cat > "$FAKECRON" <<EOF
#!/bin/bash
STORE="$TMP/crontab.txt"
touch "\$STORE"
if [ "\${1:-}" = "-l" ]; then cat "\$STORE"; exit 0; fi
if [ "\${1:-}" = "-" ]; then cat > "\$STORE"; exit 0; fi
exit 0
EOF
chmod +x "$FAKECRON"
export AFK_CRONTAB_CMD="$FAKECRON"

AFK="node bin/afk.js"
pass() { echo "ok: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# init
$AFK init >/dev/null
[ -f "$AGENTS_HOME/shared/notify.sh" ] || fail "init did not install shared/notify.sh"
[ -f "$AGENTS_HOME/shared/env.sh" ] || fail "init did not create env.sh"
pass "init creates shared/ and env.sh"

# new monitor with --every
$AFK new monitor disk-watch --every 30m >/dev/null
[ -x "$AGENTS_HOME/disk-watch/run.sh" ] || fail "monitor run.sh missing or not executable"
grep -q '^\*/30 \* \* \* \* /bin/bash .*disk-watch/run.sh # afk:disk-watch$' "$TMP/crontab.txt" || fail "monitor cron line wrong: $(cat "$TMP/crontab.txt")"
pass "new monitor --every 30m schedules */30"

# new digest with --day/--at
$AFK new digest weekly --day sun --at 19:00 >/dev/null
[ -x "$AGENTS_HOME/weekly/digest.sh" ] || fail "digest.sh missing"
grep -q '^0 19 \* \* 0 /bin/bash .*weekly/digest.sh # afk:weekly$' "$TMP/crontab.txt" || fail "digest cron line wrong: $(cat "$TMP/crontab.txt")"
pass "new digest --day sun --at 19:00 schedules '0 19 * * 0'"

# new worker without schedule
$AFK new worker triage >/dev/null
[ -x "$AGENTS_HOME/triage/worker.sh" ] || fail "worker.sh missing"
pass "new worker (no schedule) creates worker.sh"

# duplicate is rejected
if $AFK new monitor disk-watch --every 5m >/dev/null 2>&1; then fail "duplicate agent was allowed"; fi
pass "duplicate agent rejected"

# re-scheduling replaces the line, does not duplicate it
$AFK rm weekly >/dev/null
$AFK new digest weekly --schedule "0 20 * * 1" >/dev/null
[ "$(grep -c 'afk:weekly' "$TMP/crontab.txt")" = "1" ] || fail "weekly cron line duplicated"
grep -q '^0 20 \* \* 1 ' "$TMP/crontab.txt" || fail "raw --schedule not applied"
pass "rm + recreate does not duplicate cron line; raw --schedule works"

# list shows all three agents
OUT=$($AFK list)
for a in disk-watch weekly triage; do echo "$OUT" | grep -q "$a" || fail "list missing $a"; done
pass "list shows all agents"

# run executes the agent (monitor's default disk check, silent-ok path)
$AFK run disk-watch >/dev/null 2>&1 || true
[ -d "$AGENTS_HOME/disk-watch/logs" ] || fail "run did not produce a logs dir"
pass "run executes an agent"

# rm removes files and cron line
$AFK rm triage >/dev/null
[ -d "$AGENTS_HOME/triage" ] && fail "rm left the agent dir"
grep -q 'afk:triage' "$TMP/crontab.txt" && fail "rm left the cron line"
pass "rm deletes files and cron line"

echo "ALL PASS"
