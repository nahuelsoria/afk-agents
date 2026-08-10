#!/bin/bash
# shared/keep.sh: save to disk whatever an agent is about to send to chat.
#
# Why this exists: agents that generate analysis with an LLM and send it to
# Telegram leave no trace. The log says "digest sent" and nothing else, so
# weeks later there is no way to re-read what the agent recommended or to
# cross-check it against your task list. Chat history is not greppable from
# a script. With this helper every output lands on disk first and can be
# quoted, diffed or audited long after the message scrolled away.
#
# Usage:
#   source "$AGENTS_HOME/shared/keep.sh"
#   keep_output "$DIR" digest "$BODY"
#
# Leaves:
#   <DIR>/state/outputs/<slug>-YYYY-MM-DD-HHMM.txt   history
#   <DIR>/state/last-<slug>.txt                      latest, at a fixed name
#
# It never aborts the agent's run: on write failure it returns 1 and the
# caller decides (log it and continue is the norm; sending the message
# matters more than archiving it).

# Days of history to keep. These are small text files, so the default is
# long: losing the data is expensive, storing it is not.
KEEP_DAYS="${KEEP_DAYS:-365}"
# Stamp files in the timezone you think in, not the server's (often UTC).
KEEP_TZ="${KEEP_TZ:-UTC}"

keep_output() {
  local dir="$1" slug="$2" text="$3"
  [ -n "$dir" ] && [ -n "$slug" ] && [ -n "$text" ] || return 1

  local out="$dir/state/outputs"
  mkdir -p "$out" 2>/dev/null || return 1

  local stamp
  stamp=$(TZ="$KEEP_TZ" date '+%Y-%m-%d-%H%M')

  printf '%s\n' "$text" > "$out/$slug-$stamp.txt" 2>/dev/null || return 1
  printf '%s\n' "$text" > "$dir/state/last-$slug.txt" 2>/dev/null

  find "$out" -maxdepth 1 -name "$slug-*.txt" -type f -mtime "+$KEEP_DAYS" -delete 2>/dev/null
  return 0
}
