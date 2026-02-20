#!/usr/bin/env bash
# ghostrun.sh — single-script controller for tmux-ghostrun
# Subcommands: open, popup, exec, cleanup

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GHOSTRUN_LOG="/tmp/ghostrun-debug.log"

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

# ─── Hex → RGB helper ────────────────────────────────────────────────

_hex_to_rgb() {
    local hex="${1#\#}"
    printf '%d;%d;%d' "0x${hex:0:2}" "0x${hex:2:2}" "0x${hex:4:2}"
}

# ─── Color palette ───────────────────────────────────────────────────

_bg_rgb=$(_hex_to_rgb "$COLOR_BG")
_a1_rgb=$(_hex_to_rgb "$COLOR_ACCENT1")
_a2_rgb=$(_hex_to_rgb "$COLOR_ACCENT2")

_fg_rgb=$(_hex_to_rgb "$COLOR_FG")
C_ACCENT1="\033[48;2;${_a1_rgb}m\033[38;2;${_fg_rgb}m"
C_ACCENT2="\033[48;2;${_a2_rgb}m\033[38;2;${_fg_rgb}m"
C_GREEN='\033[38;2;166;218;149m'
C_RED='\033[38;2;237;135;150m'
C_YELLOW='\033[38;2;238;212;159m'
C_DIM='\033[2m'
C_BOLD='\033[1m'
C_RESET='\033[0m'

# ─── Ghost session helpers ─────────────────────────────────────────────

ghost_session_name() {
    local main="${1:-$(tmux display-message -p '#{session_name}')}"
    echo "_ghostrun_${main}"
}

ensure_ghost_session() {
    local gs="$1"
    if ! tmux has-session -t "=$gs" 2>/dev/null; then
        _log "Creating ghost session: $gs"
        local init_win
        init_win=$(tmux new-session -d -P -F '#{window_index}' -s "$gs" -x 200 -y 50 2>&1)
        if [ $? -ne 0 ] || [ -z "$init_win" ] || [[ "$init_win" == *"error"* ]] || [[ "$init_win" == *"no "* ]]; then
            _log "ensure_ghost_session: ERROR — new-session failed: $init_win"
            return 1
        fi
        tmux set-option -wt "=$gs:$init_win" remain-on-exit on
        tmux set-option -wt "=$gs:$init_win" remain-on-exit-format "" 2>/dev/null || true
        tmux set-option  -t "=$gs" status off
        tmux set-option  -t "=$gs" history-limit 5000
        _log "Ghost session created: $gs"
    fi
    return 0
}

# ─── Entry list helpers ────────────────────────────────────────────────

list_entries() {
    tmux list-windows -t "=$1" -F '#{window_index}' 2>/dev/null | sort -n
}

entry_count() {
    local c
    c=$(tmux list-windows -t "=$1" 2>/dev/null | wc -l | tr -d ' ')
    echo "${c:-0}"
}

entry_opt() {
    tmux show-option -wqv -t "=$1:$2" "$3" 2>/dev/null || true
}

entry_fmt() {
    tmux display-message -t "=$1:$2" -p "$3" 2>/dev/null || true
}

get_view_index() {
    local v
    v=$(tmux show-option -qv -t "=$1" @ghostrun-view 2>/dev/null) || true
    if [ -z "$v" ]; then
        list_entries "$1" | tail -1
    else
        echo "$v"
    fi
}

set_view_index() {
    tmux set-option -t "=$1" @ghostrun-view "$2" 2>/dev/null || true
}

# ─── Prune old entries ─────────────────────────────────────────────────

prune_entries() {
    local gs="$1"
    local count
    count=$(entry_count "$gs")
    if [ "$count" -gt "$MAX_HISTORY" ]; then
        local to_kill=$((count - MAX_HISTORY))
        list_entries "$gs" | head -n "$to_kill" | while read -r idx; do
            tmux kill-window -t "=$gs:$idx" 2>/dev/null || true
        done
    fi
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
    new_idx=$(tmux new-window -d -P -t "=$gs" -n "$cmd_short" -c "$cwd" \
        -F '#{window_index}' "sleep 3600" 2>&1)

    _log "exec: new-window returned: '$new_idx'"

    if [ -z "$new_idx" ] || [[ "$new_idx" == *"error"* ]] || [[ "$new_idx" == *"no "* ]]; then
        _log "exec: ERROR — new-window failed. Output: $new_idx"
        return 1
    fi

    tmux set-option -wt "=$gs:$new_idx" remain-on-exit on 2>/dev/null || true
    tmux set-option -wt "=$gs:$new_idx" remain-on-exit-format "" 2>/dev/null || true
    tmux set-option -wt "=$gs:$new_idx" @ghostrun-cmd  "$cmd"  2>/dev/null
    tmux set-option -wt "=$gs:$new_idx" @ghostrun-cwd  "$cwd"  2>/dev/null
    tmux set-option -wt "=$gs:$new_idx" @ghostrun-ts   "$(date +%s)" 2>/dev/null
    set_view_index "$gs" "$new_idx"

    local remain_val
    remain_val=$(tmux show-option -wqv -t "=$gs:$new_idx" remain-on-exit 2>/dev/null || true)
    _log "exec: metadata set on window $new_idx (remain-on-exit=${remain_val:-unset})"

    local respawn_out
    respawn_out=$(tmux respawn-pane -k -t "=$gs:$new_idx" -c "$cwd" sh -c "$cmd" 2>&1)
    if [ $? -ne 0 ]; then
        _log "exec: ERROR — respawn-pane failed on $new_idx: $respawn_out"
        tmux kill-window -t "=$gs:$new_idx" 2>/dev/null || true
        return 1
    fi

    # Clean up the default empty window from session creation (has no @ghostrun-cmd)
    list_entries "$gs" | while read -r idx; do
        local has_cmd
        has_cmd=$(entry_opt "$gs" "$idx" "@ghostrun-cmd")
        if [ -z "$has_cmd" ]; then
            _log "exec: killing default window $idx"
            tmux kill-window -t "=$gs:$idx" 2>/dev/null || true
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

    _log "open: session=$main_session gs=$gs cwd=$cwd"

    local mode="input"

    if tmux has-session -t "=$gs" 2>/dev/null; then
        # Check for any running command (pane_dead = 0)
        local running
        running=$(tmux list-panes -s -t "=$gs" -F '#{pane_dead}' 2>/dev/null | grep -c '^0$' || true)
        _log "open: running=$running"

        if [ "$running" -gt 0 ]; then
            mode="output"
            local running_win
            running_win=$(tmux list-panes -s -t "=$gs" \
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

    tmux display-popup -E \
        -b heavy \
        -s "bg=${COLOR_BG},fg=${COLOR_FG}" \
        -S "fg=${COLOR_BORDER}" \
        -T "$title" \
        -w "$POPUP_W" -h "$([ "$mode" = "input" ] && echo "$POPUP_H_INPUT" || echo "$POPUP_H_OUTPUT")" \
        -d "$cwd" \
        -e "GHOSTRUN_SESSION=$main_session" \
        -e "GHOSTRUN_CWD=$cwd" \
        -e "GHOSTRUN_SCRIPTS=$SCRIPTS_DIR" \
        "$SCRIPTS_DIR/ghostrun.sh" popup "$mode"
}

# ─── Subcommand: popup ─────────────────────────────────────────────────
# Wrapper that loops between input/output modes via a switch file.

cmd_popup() {
    local mode="${1:-input}"
    local main_session="${GHOSTRUN_SESSION:-$(tmux display-message -p '#{session_name}')}"
    local source_cwd="${GHOSTRUN_CWD:-$(pwd)}"
    local gs
    gs=$(ghost_session_name "$main_session")

    export GHOSTRUN_SWITCH_FILE="/tmp/ghostrun-switch-$$"
    trap 'rm -f "$GHOSTRUN_SWITCH_FILE"' EXIT

    while true; do
        rm -f "$GHOSTRUN_SWITCH_FILE"

        if [ "$mode" = "input" ]; then
            popup_input
        else
            popup_output
        fi

        # Check if a mode switch was requested
        if [ -f "$GHOSTRUN_SWITCH_FILE" ]; then
            mode=$(<"$GHOSTRUN_SWITCH_FILE")
            _log "popup: mode switch to $mode"
            continue
        fi
        break
    done
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

# ─── Output mode: display captured output, handle navigation ──────────

popup_output() {
    local gs
    gs=$(ghost_session_name "${GHOSTRUN_SESSION}")
    local source_cwd="${GHOSTRUN_CWD}"

    if ! tmux has-session -t "=$gs" 2>/dev/null; then
        echo "output" > "$GHOSTRUN_SWITCH_FILE"  # fall back — actually switch to input
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
    if ! tmux list-windows -t "=$gs" -F '#{window_index}' 2>/dev/null | grep -qx "$view_idx"; then
        view_idx=$(list_entries "$gs" | tail -1)
        set_view_index "$gs" "$view_idx"
    fi

    while true; do
        clear

        local entries_list
        entries_list=$(list_entries "$gs")
        count=$(echo "$entries_list" | wc -l | tr -d ' ')

        # Position of current view (1-based)
        local pos=0 i=0
        while read -r idx; do
            i=$((i + 1))
            [ "$idx" = "$view_idx" ] && pos=$i && break
        done <<< "$entries_list"
        [ "$pos" -eq 0 ] && pos=$count && view_idx=$(echo "$entries_list" | tail -1)

        # Entry metadata
        local cmd cwd pane_id
        cmd=$(entry_opt "$gs" "$view_idx" "@ghostrun-cmd")
        cwd=$(entry_opt "$gs" "$view_idx" "@ghostrun-cwd")
        pane_id=$(entry_fmt "$gs" "$view_idx" '#{pane_id}')

        # ── Render header ──
        printf "\n"
        local status_str
        status_str=$(render_status "$gs" "$view_idx")
        printf "  ${C_DIM}[%d/%d]${C_RESET}  ${C_BOLD}%s${C_RESET}  %b\n" "$pos" "$count" "$cmd" "$status_str"

        [ -n "$cwd" ] && printf "  ${C_DIM}%s${C_RESET}\n" "$cwd"

        # Separator
        local cols=${COLUMNS:-80}
        local sep_len=$((cols - 4))
        [ "$sep_len" -gt 80 ] && sep_len=80
        printf "  ${C_DIM}"
        printf '━%.0s' $(seq 1 "$sep_len")
        printf "${C_RESET}\n"

        # ── Render output ──
        local avail_lines=${LINES:-24}
        local output_lines=$((avail_lines - 7))
        [ "$output_lines" -lt 5 ] && output_lines=5

        if [ -n "$pane_id" ]; then
            local output
            output=$(tmux capture-pane -p -e -t "$pane_id" -S - -E - 2>/dev/null || true)
            if [ -n "$output" ]; then
                echo "$output" | awk '
                    { lines[NR] = $0 }
                    /[^[:space:]]/ { last = NR }
                    END { if (last) for (i = 1; i <= last; i++) print lines[i] }
                ' | tail -n "$output_lines" | while IFS= read -r line; do
                    printf "  %s\n" "$line"
                done
            else
                printf "\n  ${C_DIM}waiting for output...${C_RESET}\n"
            fi
        else
            printf "\n  ${C_DIM}no output available${C_RESET}\n"
        fi

        # ── Read key ──
        local dead
        dead=$(entry_fmt "$gs" "$view_idx" '#{pane_dead}')
        [ -z "$dead" ] && dead="1"
        local timeout=1
        [ "$dead" = "1" ] && timeout=""

        local key=""
        if [ -n "$timeout" ]; then
            read -rsn1 -t "$timeout" key 2>/dev/null || true
        else
            read -rsn1 key 2>/dev/null || true
        fi

        case "$key" in
            "[")
                # Previous entry
                local prev=""
                while read -r idx; do
                    [ "$idx" = "$view_idx" ] && break
                    prev="$idx"
                done <<< "$entries_list"
                if [ -n "$prev" ]; then
                    view_idx="$prev"
                    set_view_index "$gs" "$view_idx"
                fi
                ;;
            "]")
                # Next entry
                local found=0 next_idx=""
                while read -r idx; do
                    if [ "$found" -eq 1 ]; then next_idx="$idx"; break; fi
                    [ "$idx" = "$view_idx" ] && found=1
                done <<< "$entries_list"
                if [ -n "$next_idx" ]; then
                    view_idx="$next_idx"
                    set_view_index "$gs" "$view_idx"
                fi
                ;;
            "m")
                echo "input" > "$GHOSTRUN_SWITCH_FILE"
                return 0
                ;;
            "q")
                return 0
                ;;
            $'\x1b')
                read -rsn5 -t 0.01 _ 2>/dev/null || true
                return 0
                ;;
            "?")
                show_output_help
                ;;
            *)
                ;; # timeout or unknown → refresh
        esac
    done
}

# ─── Output mode helpers ──────────────────────────────────────────────

render_status() {
    local gs="$1" idx="$2"
    local dead
    dead=$(entry_fmt "$gs" "$idx" '#{pane_dead}')

    if [ "$dead" = "0" ]; then
        local start_ts now elapsed_str=""
        start_ts=$(entry_opt "$gs" "$idx" "@ghostrun-ts")
        now=$(date +%s)
        if [ -n "$start_ts" ] && [ "$start_ts" -gt 0 ] 2>/dev/null; then
            local elapsed=$((now - start_ts))
            [ "$elapsed" -ge 60 ] && elapsed_str="$((elapsed / 60))m "
            elapsed_str="${elapsed_str}$((elapsed % 60))s"
        fi
        printf "${C_YELLOW}⟳ running${C_RESET} ${C_DIM}%s${C_RESET}" "$elapsed_str"
    else
        local exit_code start_ts dead_time duration_str=""
        exit_code=$(entry_fmt "$gs" "$idx" '#{pane_dead_status}')
        start_ts=$(entry_opt "$gs" "$idx" "@ghostrun-ts")
        dead_time=$(entry_fmt "$gs" "$idx" '#{pane_dead_time}')
        if [ -n "$start_ts" ] && [ -n "$dead_time" ] && \
           [ "$start_ts" -gt 0 ] 2>/dev/null && [ "$dead_time" -gt 0 ] 2>/dev/null; then
            local dur=$((dead_time - start_ts))
            [ "$dur" -ge 60 ] && duration_str="$((dur / 60))m "
            duration_str="${duration_str}$((dur % 60))s"
        fi
        if [ "$exit_code" = "0" ]; then
            printf "${C_GREEN}✓${C_RESET} ${C_DIM}%s${C_RESET}" "$duration_str"
        else
            printf "${C_RED}✗ %s${C_RESET} ${C_DIM}%s${C_RESET}" "$exit_code" "$duration_str"
        fi
    fi
}

show_output_help() {
    clear
    local lines=${LINES:-24}
    local pad=$(( (lines - 12) / 2 ))
    [ "$pad" -lt 1 ] && pad=1
    printf '%0.s\n' $(seq 1 "$pad")
    printf "  ${C_DIM}[${C_RESET}         previous command\n"
    printf "  ${C_DIM}]${C_RESET}         next command\n"
    printf "  ${C_DIM}m${C_RESET}         switch to input\n"
    printf "  ${C_DIM}q / esc${C_RESET}   close\n"
    printf "\n  ${C_DIM}press any key${C_RESET}\n"
    read -rsn1 2>/dev/null || true
}

# ─── Subcommand: cleanup ───────────────────────────────────────────────

cmd_cleanup() {
    local session_name="$1"
    case "$session_name" in _ghostrun_*) return 0 ;; esac
    local gs
    gs=$(ghost_session_name "$session_name")
    tmux kill-session -t "=$gs" 2>/dev/null || true
}

# ─── Main dispatch ─────────────────────────────────────────────────────

case "${1:-}" in
    open)    cmd_open ;;
    popup)   shift; cmd_popup "$@" ;;
    exec)    shift; cmd_exec "$@" ;;
    cleanup) shift; cmd_cleanup "$@" ;;
    *)       echo "Usage: ghostrun.sh {open|popup|exec|cleanup}" >&2; exit 1 ;;
esac
