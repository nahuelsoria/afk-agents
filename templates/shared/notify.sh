#!/bin/bash
# Send a message to Telegram, and refuse to lose it.
#
# Usage: notify.sh "message in markdown"             -> your private chat
#        notify.sh -t <topic> "message"              -> a topic in your ops group
#        notify.sh -p HTML "<b>x</b>"                -> parse_mode HTML (default Markdown)
# Flags combine in any order: notify.sh -t infra -p HTML "msg"
#
# Topics: case-insensitive names, spaces allowed ("side project"). The mapping
# lives in shared/topics.env (TOPIC_<NAME>=thread_id plus OPS_CHAT_ID). If the
# topic is unknown or topics.env is missing, the message falls back to the
# private chat with a warning on stderr: a routing typo must never eat an alert.
#
# Delivery hardening, in order:
#   1. Markdown parse failures (HTTP 400 from unbalanced _ * [ ` in dynamic
#      content such as error bodies or LLM output) retry as plain text.
#   2. HTTP 429 rate limits (Telegram allows roughly 20 msgs/min per group)
#      wait the requested retry_after and retry to the SAME destination, so
#      a topic thread does not get split into the private chat.
#   3. Messages over 4096 chars are rejected by Telegram. They are split here
#      into chunks of at most 3500 chars on line boundaries, sent in order.
#   4. If a topic send still fails (e.g. topic deleted in the UI), the message
#      retries to the private chat as a last resort.
# Exits 1 if any chunk could not be delivered at all.
#
# Tip for callers: escape _ * [ ` in dynamic content (paths, field names) with
# a backslash, or Telegram's Markdown mode will swallow those characters.

AGENTS_HOME="${AGENTS_HOME:-$HOME/agents}"
source "$AGENTS_HOME/shared/env.sh"

CHAT="$TELEGRAM_CHAT_ID"
THREAD=""
PARSE="Markdown"

while true; do
    case "${1:-}" in
    -t)
        topic="${2:-}"
        shift 2
        TOPICS_ENV="$AGENTS_HOME/shared/topics.env"
        if [ -f "$TOPICS_ENV" ]; then
            source "$TOPICS_ENV"
            var="TOPIC_$(printf '%s' "$topic" | tr '[:lower:] ' '[:upper:]_' | tr -cd 'A-Z_')"
            tid="${!var:-}"
            if [ -n "$tid" ] && [ -n "${OPS_CHAT_ID:-}" ]; then
                CHAT="$OPS_CHAT_ID"
                THREAD="$tid"
            else
                echo "notify.sh: unknown topic '$topic'; sending to private chat" >&2
            fi
        else
            echo "notify.sh: no topics.env; sending to private chat" >&2
        fi
        ;;
    -p)
        PARSE="${2:-}"
        shift 2
        ;;
    *) break ;;
    esac
done

MSG="$1"
API="https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage"
LIMIT=3500

# _send "<parse_mode>" "<text>"  (empty parse_mode means plain text)
_send() {
    local args=(--data-urlencode "chat_id=$CHAT" --data-urlencode "text=$2")
    [ -n "$THREAD" ] && args+=(--data-urlencode "message_thread_id=$THREAD")
    [ -n "$1" ] && args+=(--data-urlencode "parse_mode=$1")
    curl -s -X POST "$API" "${args[@]}"
}

# deliver "<text>": try $PARSE, fall back to plain text. Returns 0 if delivered.
deliver() {
    local resp
    resp=$(_send "$PARSE" "$1")
    case "$resp" in *'"ok":true'*) return 0 ;; esac

    case "$resp" in *'"error_code":429'*)
        local wait="${resp#*\"retry_after\":}"
        wait="${wait%%[!0-9]*}"
        [ -z "$wait" ] && wait=5
        echo "notify.sh: Telegram rate limit, waiting ${wait}s before retry" >&2
        sleep $((wait + 1))
        resp=$(_send "$PARSE" "$1")
        case "$resp" in *'"ok":true'*) return 0 ;; esac
        ;;
    esac

    # Markdown did not parse (or the network hiccuped). Plain-text retry: the
    # * and _ show up literally, but the message arrives.
    resp=$(_send "" "$1")
    case "$resp" in *'"ok":true'*) return 0 ;; esac

    # Last resort: if this was aimed at a topic, at least reach the private chat.
    if [ -n "$THREAD" ]; then
        echo "notify.sh: topic send failed ($THREAD); retrying to private chat" >&2
        CHAT="$TELEGRAM_CHAT_ID"; THREAD=""
        resp=$(_send "" "$1")
        case "$resp" in *'"ok":true'*) return 0 ;; esac
    fi
    echo "notify.sh: Telegram send failed: ${resp:0:200}" >&2
    return 1
}

rc=0
rest="$MSG"
while [ -n "$rest" ]; do
    if [ "${#rest}" -le "$LIMIT" ]; then
        chunk="$rest"; rest=""
    else
        chunk="${rest:0:$LIMIT}"
        # Cut on the last newline inside the chunk so words and markdown
        # entities stay whole; if the chunk has no newline, cut hard.
        lastline="${chunk##*$'\n'}"
        if [ "${#lastline}" -lt "${#chunk}" ]; then
            chunk="${chunk%$'\n'*}"
            rest="${rest:$((${#chunk} + 1))}"
        else
            rest="${rest:${#chunk}}"
        fi
    fi
    [ -z "$chunk" ] && continue
    deliver "$chunk" || rc=1
done
exit $rc
