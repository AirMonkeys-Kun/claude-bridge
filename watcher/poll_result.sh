#!/bin/bash
# Fast result poller — replaces fixed sleep with tight polling
# Usage: poll_result.sh <cmd_id> [timeout_ms]
# Returns result JSON when file appears, or {"error":"timeout"} if exceeded

RID="$1"
TIMEOUT_MS="${2:-5000}"
RFILE="/sessions/practical-nice-feynman/mnt/claude-bridge/watcher/r_${RID}.json"
QFILE="/sessions/practical-nice-feynman/mnt/claude-bridge/watcher/queue.txt"

POLL_INTERVAL=0.01  # 10ms poll interval
MAX_LOOPS=$(( TIMEOUT_MS / 10 ))

for i in $(seq 1 $MAX_LOOPS); do
    if [ -f "$RFILE" ]; then
        cat "$RFILE"
        exit 0
    fi
    sleep $POLL_INTERVAL
done
echo '{"error":"timeout","cmd_id":"'$RID'"}'
exit 1
