#!/usr/bin/env bash
# ghostrun.sh — single-script controller for tmux-ghostrun
# Subcommands: open, popup, exec, nav, cleanup

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GHOSTRUN_LOG="/tmp/ghostrun-debug.log"

# Truncate log if exceeds 100KB
if [[ -f "$GHOSTRUN_LOG" && $(stat -f%z "$GHOSTRUN_LOG" 2>/dev/null || stat -c%s "$GHOSTRUN_LOG" 2>/dev/null) -gt 102400 ]]; then
    > "$GHOSTRUN_LOG"
fi

# ─── Debug logging ─────────────────────────────────────────────────────

_log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >> "$GHOSTRUN_LOG"; }

# ─── Tmux option helpers ───────────────────────────────────────────────

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

# ─── Configurable colors ─────────────────────────────────────────────

COLOR_BORDER=$(get_opt "@ghostrun-color-border" "#8b0000")
COLOR_BG=$(get_opt "@ghostrun-color-bg"         "#000000")
COLOR_FG=$(get_opt "@ghostrun-color-fg"         "#c0caf5")
COLOR_ACCENT1=$(get_opt "@ghostrun-color-accent1" "#4a1942")
COLOR_ACCENT2=$(get_opt "@ghostrun-color-accent2" "#19334a")

# ─── Ghost session helpers ─────────────────────────────────────────────

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

# ─── Entry list helpers ────────────────────────────────────────────────

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

# ─── Prune old entries ─────────────────────────────────────────────────

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

# ─── Subcommand: nav ───────────────────────────────────────────────────

cmd_nav() {
    local direction="$1"
    local gs="${2:-$(tmux display-message -p '#{session_name}')}"
    local current="${3:-}"
    local entries target=""

    if [ -z "$direction" ]; then
        return 1
    fi
    if ! tmux has-session -t "$gs" 2>/dev/null; then
        return 0
    fi

    entries=$(list_entries "$gs")
    if [ -z "$entries" ]; then
        return 0
    fi
    if [ -z "$current" ]; then
        current=$(get_view_index "$gs")
    fi
    if ! echo "$entries" | grep -qx "$current"; then
        current=$(echo "$entries" | tail -1)
    fi

    case "$direction" in
        prev)
            target=$(echo "$entries" | awk -v cur="$current" '
                $1 < cur { prev = $1 }
                END { if (prev != "") print prev }
            ')
            ;;
        next)
            target=$(echo "$entries" | awk -v cur="$current" '
                $1 > cur { print $1; exit }
            ')
            ;;
        *)
            return 1
            ;;
    esac

    if [ -n "$target" ]; then
        tmux select-window -t "$gs:$target" 2>/dev/null || true
        set_view_index "$gs" "$target"
    fi
}

# ─── Subcommand: switch-input / close ─────────────────────────────────

cmd_switch_input() {
    local gs="$1"
    local client="$2"
    if [ -z "$gs" ] || [ -z "$client" ]; then
        _log "switch-input: missing args gs='$gs' client='$client'"
        return 1
    fi

    tmux set-option -t "$gs" @ghostrun-open-mode input 2>/dev/null
    local set_rc=$?
    _log "switch-input: gs=$gs client=$client set-option-rc=$set_rc"
    tmux detach-client -t "$client" 2>/dev/null || true
}

cmd_close() {
    local client="$1"
    if [ -z "$client" ]; then
        _log "close: missing client"
        return 1
    fi
    _log "close: client=$client"
    tmux detach-client -t "$client" 2>/dev/null || true
}

# ─── Subcommand: exec ──────────────────────────────────────────────────

cmd_exec() {
    local main_session="$1"; shift
    local cwd="$1"; shift
    local cmd="$*"
    local gs
    gs=$(ghost_session_name "$main_session")

    _log "exec: session=$main_session cwd=$cwd cmd=$cmd gs=$gs"

    case "$cmd" in
        ""|*PROMPT_COMMAND*|_gr_*)
            _log "exec: ignored internal command: $cmd"
            return 2
            ;;
    esac

    if ! ensure_ghost_session "$gs"; then
        _log "exec: ERROR — failed to ensure ghost session $gs"
        return 1
    fi

    local cmd_short="${cmd:0:30}"

    # Create a new window first, configure it, then start the command.
    # This avoids a race where fast commands can exit before remain-on-exit
    # is applied.
    local new_idx
    new_idx=$(tmux new-window -d -P -t "$gs" -n "$cmd_short" -c "$cwd" \
        -F '#{window_index}' "sleep 3600" 2>&1)

    _log "exec: new-window returned: '$new_idx'"

    if [ -z "$new_idx" ] || [[ "$new_idx" == *"error"* ]] || [[ "$new_idx" == *"no "* ]]; then
        _log "exec: ERROR — new-window failed. Output: $new_idx"
        return 1
    fi

    tmux set-option -wt "$gs:$new_idx" remain-on-exit on 2>/dev/null || true
    tmux set-option -wt "$gs:$new_idx" remain-on-exit-format "" 2>/dev/null || true
    tmux set-option -wt "$gs:$new_idx" @ghostrun-cmd  "$cmd"  2>/dev/null
    tmux set-option -wt "$gs:$new_idx" @ghostrun-cwd  "$cwd"  2>/dev/null
    tmux set-option -wt "$gs:$new_idx" @ghostrun-ts   "$(date +%s)" 2>/dev/null
    set_view_index "$gs" "$new_idx"

    local remain_val
    remain_val=$(tmux show-option -wqv -t "$gs:$new_idx" remain-on-exit 2>/dev/null || true)
    _log "exec: metadata set on window $new_idx (remain-on-exit=${remain_val:-unset})"

    local respawn_out
    respawn_out=$(tmux respawn-pane -k -t "$gs:$new_idx" -c "$cwd" sh -c "$cmd" 2>&1)
    if [ $? -ne 0 ]; then
        _log "exec: ERROR — respawn-pane failed on $new_idx: $respawn_out"
        tmux kill-window -t "$gs:$new_idx" 2>/dev/null || true
        return 1
    fi

    # Clean up the default empty window from session creation (has no @ghostrun-cmd)
    list_entries "$gs" | while read -r idx; do
        local has_cmd
        has_cmd=$(entry_opt "$gs" "$idx" "@ghostrun-cmd")
        if [ -z "$has_cmd" ]; then
            _log "exec: killing default window $idx"
            tmux kill-window -t "$gs:$idx" 2>/dev/null || true
        fi
    done

    prune_entries "$gs"
    _log "exec: done"
}

# ─── Subcommand: open ──────────────────────────────────────────────────

cmd_open() {
    _log "open: script=$SCRIPTS_DIR/ghostrun.sh"
    local main_session
    main_session=$(tmux display-message -p '#{session_name}')
    local gs
    gs=$(ghost_session_name "$main_session")
    local cwd
    cwd=$(tmux display-message -p '#{pane_current_path}')
    local socket_path
    socket_path=$(tmux display-message -p '#{socket_path}')

    _log "open: session=$main_session gs=$gs cwd=$cwd"

    local mode="input"

    if tmux has-session -t "$gs" 2>/dev/null; then
        # Check for any running command (pane_dead = 0)
        local running
        running=$(tmux list-panes -s -t "$gs" -F '#{pane_dead}' 2>/dev/null | grep -c '^0$' || true)
        _log "open: running=$running"

        if [ "$running" -gt 0 ]; then
            mode="output"
            local running_win
            running_win=$(tmux list-panes -s -t "$gs" \
                -F '#{window_index} #{pane_dead}' 2>/dev/null \
                | grep ' 0$' | tail -1 | awk '{print $1}')
            [ -n "$running_win" ] && set_view_index "$gs" "$running_win"
        else
            # Check linger: did the most recent command finish recently?
            local latest_idx
            latest_idx=$(list_entries "$gs" | tail -1)
            if [ -n "$latest_idx" ]; then
                local dead_time now
                dead_time=$(entry_fmt "$gs" "$latest_idx" '#{pane_dead_time}')
                now=$(date +%s)
                if [ -n "$dead_time" ] && [ "$dead_time" -gt 0 ] 2>/dev/null; then
                    local elapsed=$((now - dead_time))
                    _log "open: latest=$latest_idx dead_time=$dead_time elapsed=$elapsed linger=$LINGER"
                    if [ "$elapsed" -lt "$LINGER" ]; then
                        mode="output"
                        set_view_index "$gs" "$latest_idx"
                    fi
                fi
            fi
        fi
    fi

    _log "open: mode=$mode"

    # Build metadata tabs for the popup title (rendered in the top border)
    local display_path="${cwd/#$HOME/~}"
    local branch
    branch=$(git -C "$cwd" branch --show-current 2>/dev/null || true)
    local dirty=""
    if [ -n "$branch" ]; then
        if ! git -C "$cwd" diff --quiet 2>/dev/null || \
           ! git -C "$cwd" diff --cached --quiet 2>/dev/null; then
            dirty=" ±"
        fi
    fi

    local title=" #[bg=${COLOR_ACCENT1},fg=${COLOR_FG}]  ${display_path} #[default]"
    if [ -n "$branch" ]; then
        title="${title}#[bg=${COLOR_ACCENT2},fg=${COLOR_FG}]  ${branch}${dirty} #[default]"
    fi
    title="${title} "

    local switch_file="/tmp/ghostrun-switch-open-$$"
    trap 'rm -f "$switch_file"' EXIT

    while true; do
        rm -f "$switch_file"
        local popup_h
        popup_h=$([ "$mode" = "input" ] && echo "$POPUP_H_INPUT" || echo "$POPUP_H_OUTPUT")

        tmux display-popup -E \
            -b heavy \
            -s "bg=${COLOR_BG},fg=${COLOR_FG}" \
            -S "fg=${COLOR_BORDER}" \
            -T "$title" \
            -w "$POPUP_W" -h "$popup_h" \
            -d "$cwd" \
            -e "GHOSTRUN_SESSION=$main_session" \
            -e "GHOSTRUN_CWD=$cwd" \
            -e "GHOSTRUN_SCRIPTS=$SCRIPTS_DIR" \
            -e "GHOSTRUN_SOCKET=$socket_path" \
            -e "GHOSTRUN_OPEN_SWITCH_FILE=$switch_file" \
            "$SCRIPTS_DIR/ghostrun.sh" popup "$mode"

        if [ -f "$switch_file" ]; then
            mode=$(<"$switch_file")
            _log "open: mode switch to $mode, reopening popup"
            continue
        fi
        break
    done
}

# ─── Subcommand: popup ─────────────────────────────────────────────────
# Wrapper that loops between input/output modes via a switch file.

cmd_popup() {
    local mode="${1:-input}"

    # Internal switch file for signaling within the popup process
    export GHOSTRUN_SWITCH_FILE="/tmp/ghostrun-switch-$$"
    trap 'rm -f "$GHOSTRUN_SWITCH_FILE"' EXIT

    rm -f "$GHOSTRUN_SWITCH_FILE"

    if [ "$mode" = "input" ]; then
        popup_input
    else
        popup_output
    fi

    # If a mode switch was requested, propagate it to the outer loop in cmd_open
    # so the popup is reopened with the correct dimensions
    if [ -f "$GHOSTRUN_SWITCH_FILE" ]; then
        local new_mode
        new_mode=$(<"$GHOSTRUN_SWITCH_FILE")
        _log "popup: propagating mode switch to $new_mode"
        if [ -n "$GHOSTRUN_OPEN_SWITCH_FILE" ]; then
            echo "$new_mode" > "$GHOSTRUN_OPEN_SWITCH_FILE"
        fi
    fi
}

# ─── Input mode: launch real bash with custom rcfile ───────────────────

popup_input() {
    _log "popup_input: launching bash --rcfile $SCRIPTS_DIR/ghostrun-inputrc.sh"
    # Silence macOS's interactive-bash deprecation banner in the popup.
    BASH_SILENCE_DEPRECATION_WARNING=1 \
    GHOSTRUN_SESSION="$GHOSTRUN_SESSION" \
    GHOSTRUN_CWD="$GHOSTRUN_CWD" \
    GHOSTRUN_SCRIPTS="$GHOSTRUN_SCRIPTS" \
    GHOSTRUN_SWITCH_FILE="$GHOSTRUN_SWITCH_FILE" \
        bash --rcfile "$SCRIPTS_DIR/ghostrun-inputrc.sh" -i
}

# ─── Output mode: native tmux viewer with popup navigation ────────────

popup_output() {
    local gs
    gs=$(ghost_session_name "${GHOSTRUN_SESSION}")
    local socket_path="${GHOSTRUN_SOCKET:-$(tmux display-message -p '#{socket_path}')}"
    local popup_tty
    local fallback_table="ghostrun-pass-$$_${RANDOM:-0}"
    local restore_file="/tmp/ghostrun-root-keys-$$_${RANDOM:-0}.tmux"
    local output_keys_installed=0

    if ! tmux has-session -t "$gs" 2>/dev/null; then
        echo "input" > "$GHOSTRUN_SWITCH_FILE"
        return 0
    fi

    local count
    count=$(entry_count "$gs")
    if [ "$count" -eq 0 ]; then
        echo "input" > "$GHOSTRUN_SWITCH_FILE"
        return 0
    fi

    # Current view index
    local view_idx
    view_idx=$(get_view_index "$gs")
    if ! tmux list-windows -t "$gs" -F '#{window_index}' 2>/dev/null | grep -qx "$view_idx"; then
        view_idx=$(list_entries "$gs" | tail -1)
        set_view_index "$gs" "$view_idx"
    fi
    if [ -z "$socket_path" ]; then
        _log "popup_output: ERROR — missing socket path"
        return 1
    fi

    popup_tty=$(tty 2>/dev/null || true)
    if [ -z "$popup_tty" ]; then
        _log "popup_output: ERROR — missing client tty"
        return 1
    fi
    _log "popup_output: gs=$gs popup_tty=$popup_tty"

    install_output_key_overrides "$popup_tty" "$fallback_table" "$restore_file" "$gs"
    output_keys_installed=1
    trap 'if [ "$output_keys_installed" -eq 1 ]; then cleanup_output_key_overrides "$fallback_table" "$restore_file"; output_keys_installed=0; fi' INT TERM HUP
    tmux set-option -t "$gs" @ghostrun-open-mode "" 2>/dev/null || true
    tmux select-window -t "$gs:$view_idx" 2>/dev/null || true
    set_view_index "$gs" "$view_idx"

    env -u TMUX tmux -S "$socket_path" attach-session -t "$gs"
    local attach_status=$?
    _log "popup_output: attach-session exit status=$attach_status"

    if [ "$output_keys_installed" -eq 1 ]; then
        cleanup_output_key_overrides "$fallback_table" "$restore_file"
        output_keys_installed=0
    fi
    trap - INT TERM HUP

    local next_mode
    next_mode=$(tmux show-option -qv -t "$gs" @ghostrun-open-mode 2>/dev/null || true)
    tmux set-option -t "$gs" @ghostrun-open-mode "" 2>/dev/null || true
    if [ "$next_mode" = "input" ]; then
        echo "input" > "$GHOSTRUN_SWITCH_FILE"
    fi
}

# ─── Subcommand: cleanup ───────────────────────────────────────────────

cmd_cleanup() {
    local session_name="$1"
    case "$session_name" in _ghostrun_*) return 0 ;; esac
    local gs
    gs=$(ghost_session_name "$session_name")
    tmux kill-session -t "$gs" 2>/dev/null || true
}

# ─── Main dispatch ─────────────────────────────────────────────────────

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
