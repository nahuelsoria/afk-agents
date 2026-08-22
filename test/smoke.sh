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

# ---- regressions: the crontab is somebody else's file ------------------------

# A cron line whose marker is a prefix of ours must survive `rm`.
echo "0 5 * * * /bin/bash /somewhere/else.sh # afk:disk-watch-old" >> "$TMP/crontab.txt"
$AFK new monitor tmp-neighbour --every 15m >/dev/null
$AFK rm tmp-neighbour >/dev/null
grep -q 'afk:disk-watch-old' "$TMP/crontab.txt" || fail "rm deleted a line whose marker was only a prefix match"
pass "marker matching does not eat neighbouring lines"

# A crontab that cannot be READ must never be WRITTEN. This is the one that
# could wipe every entry the user had.
BADCRON="$TMP/badcron"
cat > "$BADCRON" <<EOF
#!/bin/bash
if [ "\${1:-}" = "-l" ]; then echo "crontab: cannot open spool" >&2; exit 1; fi
if [ "\${1:-}" = "-" ]; then cat > "$TMP/badcron-write.txt"; exit 0; fi
exit 0
EOF
chmod +x "$BADCRON"
rm -f "$TMP/badcron-write.txt"
if AFK_CRONTAB_CMD="$BADCRON" $AFK new monitor doomed --every 10m >/dev/null 2>"$TMP/err.txt"; then
    fail "new succeeded even though the crontab could not be read"
fi
[ -f "$TMP/badcron-write.txt" ] && fail "wrote the crontab after failing to read it (would drop every user entry)"
grep -qi 'refusing to touch it' "$TMP/err.txt" || fail "unreadable crontab did not produce the refusal message: $(cat "$TMP/err.txt")"
pass "an unreadable crontab is refused, not overwritten"

# "no crontab for <user>" still means empty, not an error.
EMPTYCRON="$TMP/emptycron"
cat > "$EMPTYCRON" <<EOF
#!/bin/bash
STORE="$TMP/emptycron.txt"
touch "\$STORE"
if [ "\${1:-}" = "-l" ]; then
    if [ -s "\$STORE" ]; then cat "\$STORE"; exit 0; fi
    echo "no crontab for nobody" >&2; exit 1
fi
if [ "\${1:-}" = "-" ]; then cat > "\$STORE"; exit 0; fi
exit 0
EOF
chmod +x "$EMPTYCRON"
AFK_CRONTAB_CMD="$EMPTYCRON" AGENTS_HOME="$TMP/agents2" $AFK init >/dev/null
AFK_CRONTAB_CMD="$EMPTYCRON" AGENTS_HOME="$TMP/agents2" $AFK new monitor first --every 20m >/dev/null
grep -q 'afk:first' "$TMP/emptycron.txt" || fail "first agent on an empty crontab was not scheduled"
pass "an empty crontab is still treated as empty"

# ---- regressions: bad flags fail with a message, not a stack trace ----------

if $AFK new monitor bogus --schedule "no soy cron" >/dev/null 2>"$TMP/err.txt"; then
    fail "--schedule accepted a non-cron string"
fi
grep -q '5 cron fields' "$TMP/err.txt" || fail "--schedule rejection message unclear: $(cat "$TMP/err.txt")"
[ -d "$AGENTS_HOME/bogus" ] && fail "--schedule rejection still created the agent dir"

if $AFK new monitor bogus2 --schedule "0 3 * * * echo hola" >/dev/null 2>&1; then
    fail "--schedule accepted 6 fields (cron would run the extra field as a command)"
fi
pass "--schedule validates the cron expression"

if $AFK new monitor bogus3 --every >/dev/null 2>"$TMP/err.txt"; then
    fail "--every with no value succeeded"
fi
grep -q 'needs a value' "$TMP/err.txt" || fail "--every without value did not print a usage message: $(cat "$TMP/err.txt")"
grep -qi 'TypeError\|at Object\.' "$TMP/err.txt" && fail "--every without value printed a raw stack trace"
pass "flags without a value fail with a message, not a stack trace"

echo "ALL PASS"
