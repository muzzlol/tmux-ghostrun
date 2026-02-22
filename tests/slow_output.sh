#!/usr/bin/env bash
# Long-running task: trickles output line-by-line over time.
# Tests that the output popup stays live and scrollable during an active command.
#
# Usage: tests/slow_output.sh [lines] [delay_ms]
#   lines     — total lines to emit   (default: 60)
#   delay_ms  — ms between lines      (default: 500)

LINES=${1:-60}
DELAY=$(echo "${2:-500} 1000" | awk '{printf "%.3f", $1/$2}')

echo "==> Starting slow output: $LINES lines, ${2:-500}ms apart"
echo ""

for i in $(seq 1 "$LINES"); do
    pct=$(( i * 100 / LINES ))
    bar_len=30
    filled=$(( pct * bar_len / 100 ))
    bar=$(printf '%0.s#' $(seq 1 $filled))
    space=$(printf '%0.s-' $(seq 1 $(( bar_len - filled ))))
    rand=$(head -c 12 /dev/urandom | base64 | tr -d '\n=' | head -c 16)
    printf "[%s%s] %3d%% | line %3d/%d | %s\n" "$bar" "$space" "$pct" "$i" "$LINES" "$rand"
    sleep "$DELAY"
done

echo ""
echo "==> Done. Exit 0."
