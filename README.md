# tmux-ghostrun

`tmux-ghostrun` is a popup command runner for tmux:
- input popup captures a command and runs it in a hidden ghost session
- output popup shows that command's pane using a native tmux client

https://github.com/muzzlol/tmux-ghostrun/raw/main/showcase.mp4

## Install

**With [TPM](https://github.com/tmux-plugins/tpm):**
```
set -g @plugin 'muzzlol/tmux-ghostrun'
```
Then press `prefix + I` to install.

**Manually:**
```bash
git clone https://github.com/muzzlol/tmux-ghostrun ~/.tmux/tmux-ghostrun
```
Add to `~/.tmux.conf`:
```
run-shell ~/.tmux/tmux-ghostrun/tmux-ghostrun.tmux
```

## Usage

Press `prefix + Space` to open the input popup, type a command, and press `Enter`. The command runs in a hidden session. Press `prefix + Space` again to view the output.

## Output mode keys
> **Note:** Output keys are active only while the output popup is open.

- `[`/`]` to move to previous/next output; native tmux session-switch bindings still work, so you can use them to move across ghostrun outputs.
- `Up` / `Down` scroll output (copy-mode aware)
- `m` switch back to input mode
- `q` or `Esc` close output popup


## Options

- `@ghostrun-bind` (default: `Space`)
- `@ghostrun-linger` (default: `20`)
- `@ghostrun-history` (default: `30`)
- `@ghostrun-popup-w` (default: `75%`)
- `@ghostrun-popup-h-input` (default: `7`)
- `@ghostrun-popup-h-output` (default: `50%`)

Color options:
- `@ghostrun-color-border`
- `@ghostrun-color-bg`
- `@ghostrun-color-fg`
- `@ghostrun-color-accent1`
- `@ghostrun-color-accent2`
