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

# ─── Build static PS1 (computed once — popup only takes one command) ───

_gr_dir=$(basename "${GHOSTRUN_CWD:-$PWD}")
_gr_branch=$(git -C "${GHOSTRUN_CWD:-$PWD}" branch --show-current 2>/dev/null || true)
_gr_dirty=""
if [ -n "$_gr_branch" ]; then
    if ! git -C "${GHOSTRUN_CWD:-$PWD}" diff --quiet 2>/dev/null || \
       ! git -C "${GHOSTRUN_CWD:-$PWD}" diff --cached --quiet 2>/dev/null; then
        _gr_dirty=" ±"
    fi
fi

# Colored metadata blocks matching catppuccin theme
_gr_meta="  \[\033[48;2;45;27;78m\033[38;2;255;255;255m\]   ${_gr_dir} \[\033[0m\]"
if [ -n "$_gr_branch" ]; then
    _gr_meta="${_gr_meta} \[\033[48;2;30;58;95m\033[38;2;255;255;255m\]  ${_gr_branch}${_gr_dirty} \[\033[0m\]"
fi
PS1="\n${_gr_meta}\n\n  ❯ "

# ─── Initial screen layout (clear + vertical padding for spacious feel) ─

clear
_gr_pad=$(( ${LINES:-24} * 30 / 100 ))
[ "$_gr_pad" -lt 2 ] && _gr_pad=2
printf '%0.s\n' $(seq 1 "$_gr_pad")

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
            printf "\n\033[1m  ghostrun\033[0m\n\n"
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
