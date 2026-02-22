#!/usr/bin/env bash
# ghostrun.sh — modular controller for tmux-ghostrun
# Subcommands: open, popup, exec, nav, cleanup

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/ghostrun/common.sh
source "$SCRIPTS_DIR/ghostrun/common.sh"
# shellcheck source=scripts/ghostrun/commands.sh
source "$SCRIPTS_DIR/ghostrun/commands.sh"
# shellcheck source=scripts/ghostrun/popup.sh
source "$SCRIPTS_DIR/ghostrun/popup.sh"

case "${1:-}" in
    open)    cmd_open ;;
    popup)   shift; cmd_popup "$@" ;;
    exec)    shift; cmd_exec "$@" ;;
    nav)     shift; cmd_nav "$@" ;;
    switch-input) shift; cmd_switch_input "$@" ;;
    close)   shift; cmd_close "$@" ;;
    cleanup) shift; cmd_cleanup "$@" ;;
    *)       echo "Usage: ghostrun.sh {open|popup|exec|nav|switch-input|close|cleanup}" >&2; exit 1 ;;
esac
