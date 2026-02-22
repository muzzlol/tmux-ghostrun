#!/usr/bin/env bash
# Mixed output stress test: interleaved stdout/stderr, ANSI colours, long lines.
# Tests that the output popup handles realistic "noisy" command output correctly:
#   - stderr and stdout arriving interleaved
#   - ANSI colour/bold escape sequences
#   - very long lines (tests horizontal truncation / wrapping behaviour)
#   - blank lines and dense bursts
#
# Usage: tests/mixed_output.sh [lines]
#   lines — approximate number of output lines (default: 80)

LINES=${1:-80}

# ANSI helpers
RED='\033[0;31m'
YEL='\033[0;33m'
GRN='\033[0;32m'
BLU='\033[0;34m'
CYN='\033[0;36m'
BLD='\033[1m'
RST='\033[0m'

rand16() { head -c 12 /dev/urandom | base64 | tr -d '\n=/' | head -c 16; }

echo -e "${BLD}==> mixed_output.sh — ${LINES} lines${RST}"
echo ""

for i in $(seq 1 "$LINES"); do
    r=$(( RANDOM % 6 ))
    case $r in
        0)
            # Normal info line
            echo -e "${BLU}[INFO ]${RST}  line $i — $(rand16) $(rand16)"
            ;;
        1)
            # Warning to stderr
            echo -e "${YEL}[WARN ]${RST}  line $i — something smells off: $(rand16)" >&2
            ;;
        2)
            # Error to stderr
            echo -e "${RED}[ERROR]${RST}  line $i — non-fatal: $(rand16) code=$(( RANDOM % 127 + 1 ))" >&2
            ;;
        3)
            # Success / green
            echo -e "${GRN}[OK   ]${RST}  line $i — processed $(rand16)"
            ;;
        4)
            # Very long line (tests wrapping)
            long=""
            for _ in $(seq 1 8); do long="${long}$(rand16) "; done
            echo -e "${CYN}[LONG ]${RST}  line $i — $long"
            ;;
        5)
            # Blank separator
            echo ""
            ;;
    esac

    # Burst a few lines without delay occasionally, then pause
    if (( i % 10 == 0 )); then
        sleep 0.1
    fi
done

echo ""
echo -e "${GRN}${BLD}==> Done. Exit 0.${RST}"
