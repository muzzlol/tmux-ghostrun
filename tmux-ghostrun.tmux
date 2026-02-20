#!/usr/bin/env bash
# tmux-ghostrun - fire-and-forget command runner overlay
# https://github.com/muzzlol/tmux-ghostrun

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$CURRENT_DIR/scripts"

# --- Read user-configurable bind key (default: Space) ---

get_opt() {
    local val
    val=$(tmux show-option -gqv "$1" 2>/dev/null)
    echo "${val:-$2}"
}

BIND_KEY=$(get_opt "@ghostrun-bind" "Space")

# --- Key binding: prefix + $BIND_KEY opens ghostrun ---

tmux bind-key "$BIND_KEY" run-shell "$SCRIPTS_DIR/ghostrun.sh open"

# --- Cleanup hook: destroy ghost session when parent session dies ---

# Note: tmux double quotes needed so #{hook_session_name} gets format-expanded at trigger time.
# Shell single quotes protect the expanded name from word splitting.
tmux set-hook -g session-closed \
    "run-shell \"${SCRIPTS_DIR}/ghostrun.sh cleanup '#{hook_session_name}'\""

# --- Filter ghost sessions from choose-tree (prefix + s) ---

tmux bind-key s choose-tree -Zs -f '#{?#{m:_ghostrun_*,#{session_name}},0,1}'
