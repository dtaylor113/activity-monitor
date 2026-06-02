#!/usr/bin/env bash
# Auto-refresh loop for Activity Monitor
# Runs gather.sh + assemble.py every 30 minutes.
# Designed to run as a background Cursor terminal.
#
# Usage:
#   bash scripts/auto-refresh.sh
#
# Stop: close the terminal or Ctrl+C
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INTERVAL_SEC=1800  # 30 minutes
GATHER="$SCRIPT_DIR/gather.sh"
ASSEMBLE="$SCRIPT_DIR/assemble.py"
TMPFILE=$(mktemp /tmp/activity-gather.XXXXXX)

trap 'rm -f "$TMPFILE"; echo "[activity-monitor] Stopped."; exit 0' INT TERM

echo "[activity-monitor] Auto-refresh started (every ${INTERVAL_SEC}s)"
echo "[activity-monitor] Output: $PROJECT_DIR/activity-data.js"
echo ""

while true; do
    SINCE=$(date -v-3d +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -d "-3 days" +%Y-%m-%dT%H:%M:%S)
    
    echo "[activity-monitor] Gathering data (since $SINCE)..."
    if bash "$GATHER" --since "$SINCE" > "$TMPFILE" 2>/dev/null; then
        if python3 "$ASSEMBLE" "$TMPFILE" "$PROJECT_DIR"; then
            echo "[activity-monitor] Refreshed at $(date +%H:%M:%S) — browser reload to see changes"
        else
            echo "[activity-monitor] ERROR: Assembly failed at $(date +%H:%M:%S)"
        fi
    else
        echo "[activity-monitor] ERROR: Gather failed at $(date +%H:%M:%S)"
    fi

    echo "[activity-monitor] Next refresh at $(date -v+${INTERVAL_SEC}S +%H:%M 2>/dev/null || date -d "+${INTERVAL_SEC} seconds" +%H:%M)"
    sleep "$INTERVAL_SEC"
done
