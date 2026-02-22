#!/usr/bin/env bash
# Failing task: does real work, then exits non-zero.
# Tests that remain-on-exit keeps the pane alive so the error is visible in the
# output popup after the command finishes.
#
# Usage: tests/fail.sh [exit_code]
#   exit_code — the code to exit with (default: 1)

EXIT_CODE=${1:-1}

echo "==> Running pre-flight checks..."
sleep 0.4

steps=(
    "Checking dependencies"
    "Validating config"
    "Connecting to remote"
    "Fetching data"
    "Processing results"
)

for step in "${steps[@]}"; do
    printf "  [ ] %s..." "$step"
    sleep 0.3
    echo " OK"
done

echo ""
echo "==> All pre-flight checks passed."
echo "==> Attempting critical operation..."
sleep 0.5

echo ""
echo "ERROR: critical operation failed (simulated)." >&2
echo "  reason : exit code $EXIT_CODE requested" >&2
echo "  hint   : this is tests/fail.sh — it always exits non-zero" >&2
echo ""

exit "$EXIT_CODE"
