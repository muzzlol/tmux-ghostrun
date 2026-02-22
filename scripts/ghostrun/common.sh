#!/usr/bin/env bash

GHOSTRUN_LOG="/tmp/ghostrun-debug.log"

# Truncate log if exceeds 100KB
if [[ -f "$GHOSTRUN_LOG" && $(stat -f%z "$GHOSTRUN_LOG" 2>/dev/null || stat -c%s "$GHOSTRUN_LOG" 2>/dev/null) -gt 102400 ]]; then
    > "$GHOSTRUN_LOG"
fi

_log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >> "$GHOSTRUN_LOG"; }

get_opt() {
    local val
    val=$(tmux show-option -gqv "$1" 2>/dev/null) || true
    echo "${val:-$2}"
}

LINGER=$(get_opt "@ghostrun-linger"  "20")
MAX_HISTORY=$(get_opt "@ghostrun-history" "30")
POPUP_W=$(get_opt "@ghostrun-popup-w" "75%")
POPUP_H_INPUT=$(get_opt "@ghostrun-popup-h-input" "7")
POPUP_H_OUTPUT=$(get_opt "@ghostrun-popup-h-output" "50%")

COLOR_BORDER=$(get_opt "@ghostrun-color-border" "#8b0000")
COLOR_BG=$(get_opt "@ghostrun-color-bg"         "#000000")
COLOR_FG=$(get_opt "@ghostrun-color-fg"         "#c0caf5")
COLOR_ACCENT1=$(get_opt "@ghostrun-color-accent1" "#4a1942")
COLOR_ACCENT2=$(get_opt "@ghostrun-color-accent2" "#19334a")

ghost_session_name() {
    local main="${1:-$(tmux display-message -p '#{session_name}')}"
    echo "_ghostrun_${main}"
}

ensure_ghost_session() {
    local gs="$1"
    if ! tmux has-session -t "$gs" 2>/dev/null; then
        _log "Creating ghost session: $gs"
        local init_win
        init_win=$(tmux new-session -d -P -F '#{window_index}' -s "$gs" -x 200 -y 50 2>&1)
        if [ $? -ne 0 ] || [ -z "$init_win" ] || [[ "$init_win" == *"error"* ]] || [[ "$init_win" == *"no "* ]]; then
            _log "ensure_ghost_session: ERROR — new-session failed: $init_win"
            return 1
        fi
        tmux set-option -wt "$gs:$init_win" remain-on-exit on
        tmux set-option -wt "$gs:$init_win" remain-on-exit-format "" 2>/dev/null || true
        tmux set-option  -t "$gs" status off
        tmux set-option  -t "$gs" history-limit 5000
        _log "Ghost session created: $gs"
    fi
    return 0
}

list_entries() {
    tmux list-windows -t "$1" -F '#{window_index}' 2>/dev/null | sort -n
}

entry_count() {
    local c
    c=$(tmux list-windows -t "$1" 2>/dev/null | wc -l | tr -d ' ')
    echo "${c:-0}"
}

entry_opt() {
    tmux show-option -wqv -t "$1:$2" "$3" 2>/dev/null || true
}

entry_fmt() {
    tmux display-message -t "$1:$2" -p "$3" 2>/dev/null || true
}

get_view_index() {
    local v
    v=$(tmux show-option -qv -t "$1" @ghostrun-view 2>/dev/null) || true
    if [ -z "$v" ]; then
        list_entries "$1" | tail -1
    else
        echo "$v"
    fi
}

set_view_index() {
    tmux set-option -t "$1" @ghostrun-view "$2" 2>/dev/null || true
}

install_output_key_override() {
    local popup_tty="$1"
    local fallback_table="$2"
    local restore_file="$3"
    local key="$4"
    local action_cmd="$5"
    local default_fallback_cmd="$6"
    local existing_line
    local fallback_line
    local fallback_cmd
    local have_fallback=0

    existing_line=$(tmux list-keys -T root "$key" 2>/dev/null | head -n 1 || true)
    if [ -n "$existing_line" ]; then
        printf '%s\n' "$existing_line" >> "$restore_file"
        fallback_line="${existing_line/-T root/-T $fallback_table}"
        if tmux source-file - <<<"$fallback_line" 2>/dev/null; then
            have_fallback=1
        fi
    fi
    if [ "$have_fallback" -eq 0 ]; then
        tmux bind-key -T "$fallback_table" "$key" $default_fallback_cmd 2>/dev/null || true
    fi

    fallback_cmd="switch-client -T '$fallback_table' \\; send-keys -K -c '#{client_name}' '$key'"
    tmux bind-key -T root "$key" \
        if-shell -F "#{==:#{client_tty},$popup_tty}" \
        "$action_cmd" \
        "$fallback_cmd" 2>/dev/null || true
}

install_output_key_overrides() {
    local popup_tty="$1"
    local fallback_table="$2"
    local restore_file="$3"
    local gs="$4"

    : > "$restore_file"
    tmux unbind-key -a -q -T "$fallback_table" 2>/dev/null || true

    install_output_key_override "$popup_tty" "$fallback_table" "$restore_file" "[" \
        "run-shell \"$SCRIPTS_DIR/ghostrun.sh nav prev '$gs'\"" \
        "send-keys -H 5b"
    install_output_key_override "$popup_tty" "$fallback_table" "$restore_file" "]" \
        "run-shell \"$SCRIPTS_DIR/ghostrun.sh nav next '$gs'\"" \
        "send-keys -H 5d"

    install_output_key_override "$popup_tty" "$fallback_table" "$restore_file" Up \
        "if-shell -F '#{pane_in_mode}' 'send-keys -X scroll-up' 'copy-mode -eu'" \
        "send-keys Up"
    install_output_key_override "$popup_tty" "$fallback_table" "$restore_file" Down \
        "if-shell -F '#{pane_in_mode}' 'send-keys -X scroll-down' 'copy-mode -ed'" \
        "send-keys Down"

    install_output_key_override "$popup_tty" "$fallback_table" "$restore_file" m \
        "run-shell \"$SCRIPTS_DIR/ghostrun.sh switch-input '$gs' '#{client_name}'\"" \
        "send-keys -l m"
    install_output_key_override "$popup_tty" "$fallback_table" "$restore_file" q \
        "run-shell \"$SCRIPTS_DIR/ghostrun.sh close '#{client_name}'\"" \
        "send-keys -l q"
    install_output_key_override "$popup_tty" "$fallback_table" "$restore_file" Escape \
        "run-shell \"$SCRIPTS_DIR/ghostrun.sh close '#{client_name}'\"" \
        "send-keys Escape"
}

cleanup_output_key_overrides() {
    local fallback_table="$1"
    local restore_file="$2"

    tmux unbind-key -q -T root "[" 2>/dev/null || true
    tmux unbind-key -q -T root "]" 2>/dev/null || true
    tmux unbind-key -q -T root Up 2>/dev/null || true
    tmux unbind-key -q -T root Down 2>/dev/null || true
    tmux unbind-key -q -T root m 2>/dev/null || true
    tmux unbind-key -q -T root q 2>/dev/null || true
    tmux unbind-key -q -T root Escape 2>/dev/null || true

    if [ -s "$restore_file" ]; then
        tmux source-file "$restore_file" 2>/dev/null || true
    fi

    tmux unbind-key -a -q -T "$fallback_table" 2>/dev/null || true
    rm -f "$restore_file"
}

prune_entries() {
    local gs="$1"
    local count
    count=$(entry_count "$gs")
    if [ "$count" -gt "$MAX_HISTORY" ]; then
        local to_kill=$((count - MAX_HISTORY))
        list_entries "$gs" | head -n "$to_kill" | while read -r idx; do
            tmux kill-window -t "$gs:$idx" 2>/dev/null || true
        done
    fi
}
