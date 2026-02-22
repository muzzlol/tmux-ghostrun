#!/usr/bin/env bash

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

configure_output_status() {
    local gs="$1"

    tmux set-option -t "$gs" status on
    tmux set-option -t "$gs" status-position bottom
    tmux set-option -t "$gs" status-style "bg=#111111,fg=#666666"
    tmux set-option -t "$gs" status-interval 1

    # Single status-format line — no window list
    # Left: icon │ position │ time   Right: key hints
    local fmt='#[align=left]'
    # Icon: spinner (running) / tick (success) / cross+code (failure)
    fmt+="#{?#{pane_dead},#{?#{==:#{pane_dead_status},0},#[fg=green] ✓,#[fg=red] ✗ #{pane_dead_status}},#[fg=yellow] #($SCRIPTS_DIR/ghostrun/spinner.sh)}"
    # Separator + position (stored option, updated on every nav)
    fmt+=' #[fg=#444444]│ #[fg=#666666]#{@ghostrun-view-pos}'
    # Separator + elapsed time (pure tmux formats; avoid #() async/cached stale values)
    fmt+=' #[fg=#444444]│ #[fg=#666666]#{?#{pane_dead},#{?#{&&:#{m/r:^[0-9]+$,#{@ghostrun-ts}},#{m/r:^[0-9]+$,#{pane_dead_time}},#{>=:#{pane_dead_time},#{@ghostrun-ts}}},#{?#{e|>=:#{e|-:#{pane_dead_time},#{@ghostrun-ts}},60},#{e|/:#{e|-:#{pane_dead_time},#{@ghostrun-ts}},60}m#{e|m:#{e|-:#{pane_dead_time},#{@ghostrun-ts}},60}s,#{e|-:#{pane_dead_time},#{@ghostrun-ts}}s},n/a},run}'
    # Right side
    fmt+='#[align=right]'
    fmt+='#[fg=white]q #[fg=#666666]quit #[fg=#444444]│ #[fg=white]m #[fg=#666666]input #[fg=#444444]│ #[fg=white][ ] #[fg=#666666]nav '

    tmux set-option -t "$gs" 'status-format[0]' "$fmt"
}

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
    install_view_sync_hooks "$gs"
    output_keys_installed=1
    trap 'if [ "$output_keys_installed" -eq 1 ]; then cleanup_output_key_overrides "$fallback_table" "$restore_file"; output_keys_installed=0; fi' INT TERM HUP
    tmux set-option -t "$gs" @ghostrun-open-mode "" 2>/dev/null || true
    tmux select-window -t "$gs:$view_idx" 2>/dev/null || true
    set_view_index "$gs" "$view_idx"
    configure_output_status "$gs"

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
