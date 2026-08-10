#!/bin/bash
# Usage: log.sh "<agent>" "<message>"
# Appends one timestamped line to the agent's daily log file:
#   $AGENTS_HOME/<agent>/logs/YYYY-MM-DD.log
# Daily files keep logs greppable by date and trivially rotatable with find.

AGENTS_HOME="${AGENTS_HOME:-$HOME/agents}"
AGENT="$1"
MSG="$2"
DATE=$(date +%Y-%m-%d)
TIME=$(date +%H:%M:%S)
LOG_DIR="$AGENTS_HOME/$AGENT/logs"
mkdir -p "$LOG_DIR"
echo "[$TIME] $MSG" >> "$LOG_DIR/$DATE.log"
