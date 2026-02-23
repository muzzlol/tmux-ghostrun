#!/usr/bin/env bash

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

cmd_sync_view() {
    local gs="$1"
    local idx="${2:-}"

    if [ -z "$gs" ]; then
        _log "sync-view: missing session"
        return 1
    fi
    if ! tmux has-session -t "$gs" 2>/dev/null; then
        return 0
    fi

    if [ -z "$idx" ]; then
        idx=$(tmux display-message -p -t "$gs" '#{window_index}' 2>/dev/null || true)
    fi
    if ! tmux list-windows -t "$gs" -F '#{window_index}' 2>/dev/null | grep -qx "$idx"; then
        idx=$(list_entries "$gs" | tail -1)
    fi
    [ -n "$idx" ] && set_view_index "$gs" "$idx"
}

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
    respawn_out=$(tmux respawn-pane -k -t "$gs:$new_idx" -c "$cwd" \
        sh -c 'printf "\n\033[38;5;245m$ %s\033[0m\n" "$0"; eval "$0"' "$cmd" 2>&1)
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
    set_view_index "$gs" "$new_idx"
    _log "exec: done"
}

cmd_cleanup() {
    local session_name="$1"
    case "$session_name" in _ghostrun_*) return 0 ;; esac
    local gs
    gs=$(ghost_session_name "$session_name")
    tmux kill-session -t "$gs" 2>/dev/null || true
}
