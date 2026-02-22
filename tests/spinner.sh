#!/usr/bin/env bash
# Spinner / in-place progress bar.
# Tests that the output popup correctly handles carriage-return (\r) rewriting
# of a single line — the same rendering path used by curl, wget, npm, etc.
# After the spinner finishes, a multi-step build log follows to confirm that
# normal line output still works after in-place updates.
#
# Usage: tests/spinner.sh [steps]
#   steps — number of spinner ticks before "build" phase (default: 40)

STEPS=${1:-40}

GRN='\033[0;32m'
YEL='\033[0;33m'
CYN='\033[0;36m'
BLD='\033[1m'
RST='\033[0m'

spin_chars='|/-\'

echo -e "${BLD}==> spinner.sh${RST}"
echo ""

# ── Phase 1: classic spinner ──────────────────────────────────────────────────
printf "    Spinning"
for i in $(seq 1 "$STEPS"); do
    idx=$(( (i - 1) % 4 ))
    c="${spin_chars:$idx:1}"
    printf " %s\r    Spinning" "$c"
    sleep 0.08
done
printf "   \n"                         # clear the spinner char
echo -e "    ${GRN}Spin complete.${RST}"
echo ""

# ── Phase 2: wget-style download bar ─────────────────────────────────────────
BAR_W=40
TOTAL=100
echo -e "    ${CYN}Simulated download:${RST}"
for i in $(seq 0 5 "$TOTAL"); do
    filled=$(( i * BAR_W / TOTAL ))
    bar=$(printf '%0.s=' $(seq 1 $filled) 2>/dev/null; printf '%0.s ' $(seq 1 $(( BAR_W - filled )) ) 2>/dev/null)
    kbps=$(( 800 + RANDOM % 400 ))
    printf "    [%s] %3d%%  %d KB/s\r" "$bar" "$i" "$kbps"
    sleep 0.05
done
printf "    [%s] 100%%  done         \n" "$(printf '%0.s=' $(seq 1 $BAR_W))"
echo ""

# ── Phase 3: normal multi-line build log (post-spinner sanity check) ──────────
build_steps=(
    "Compiling module A"
    "Compiling module B"
    "Linking objects"
    "Running tests"
    "Packaging artifact"
)

echo -e "    ${BLD}Build log:${RST}"
for step in "${build_steps[@]}"; do
    echo -e "      ${YEL}>>>${RST} $step..."
    sleep 0.2
    echo -e "          done"
done

echo ""
echo -e "${GRN}${BLD}==> All phases complete. Exit 0.${RST}"
