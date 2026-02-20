# ghostrun-inputrc.sh — sourced by bash inside the ghostrun popup (input mode)
# Gives a real shell with tab completion, then intercepts the command and
# routes it to the ghost session instead of running it locally.

# ─── Load user's shell environment (completions, aliases, etc.) ────────

[ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc" 2>/dev/null || true
[ -f "$HOME/.bash_profile" ] && source "$HOME/.bash_profile" 2>/dev/null || true

# Undo any strict modes the user's rc files might have set
set +e +u +o pipefail 2>/dev/null

# Disable any user PROMPT_COMMAND hooks inside the popup shell. We only want
# to intercept real commands typed by the user in this one-shot input shell.
unset PROMPT_COMMAND 2>/dev/null || true

# ─── Prompt (metadata is in the popup title/border) ──────────────────

PS1="\n  ❯ "

# ─── Initial screen layout ───────────────────────────────────────────

clear
printf "\n"

# ─── Command interception via prompt-armed DEBUG trap ──────────────────

_gr_ready=0
_gr_armed=0

_gr_arm() {
    # Runs via PROMPT_COMMAND right before each prompt draw.
    # This arms interception for exactly one upcoming command.
    _gr_armed=1
}

_gr_intercept() {
    # Ignore everything until setup is fully done.
    [ "$_gr_ready" -eq 0 ] && return 0
    # Intercept only the first command after a prompt is shown.
    [ "$_gr_armed" -eq 0 ] && return 0

    # Consume arm immediately so helper calls below don't retrigger handling.
    _gr_armed=0

    # Ignore our own internals if they appear here.
    case "$BASH_COMMAND" in
        _gr_*|"") return 0 ;;
    esac

    # Prefer the full command line from history (covers `&&`, `;`, pipes).
    local cmd="$BASH_COMMAND"
    local hist_cmd
    hist_cmd=$(history 1 2>/dev/null | sed 's/^ *[0-9][0-9]*[[:space:]]*//')
    [ -n "$hist_cmd" ] && cmd="$hist_cmd"

    local cmd_trim="$cmd"
    cmd_trim="${cmd_trim#"${cmd_trim%%[![:space:]]*}"}"
    cmd_trim="${cmd_trim%"${cmd_trim##*[![:space:]]}"}"

    case "$cmd_trim" in
        "")
            return 0
            ;;
        "[")
            echo "output" > "$GHOSTRUN_SWITCH_FILE"
            exit 0
            ;;
        "?")
            printf "\n"
            printf "  \033[2mcommand\033[0m   run in background, popup closes\n"
            printf "  \033[2m[\033[0m         switch to output view\n"
            printf "  \033[2mtab\033[0m       shell completion (normal)\n"
            printf "  \033[2mctrl-c\033[0m    close\n"
            printf "\n"
            return 1
            ;;
        ":q"|":quit")
            exit 0
            ;;
    esac

    if "$GHOSTRUN_SCRIPTS/ghostrun.sh" exec "$GHOSTRUN_SESSION" "$GHOSTRUN_CWD" "$cmd"; then
        exit 0
    fi
    # Prevent local execution even if dispatch failed; keep popup open.
    return 1
}

shopt -s extdebug
trap '_gr_intercept' DEBUG
PROMPT_COMMAND="_gr_arm"
_gr_ready=1
