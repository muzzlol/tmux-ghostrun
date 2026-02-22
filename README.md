# tmux-ghostrun

`tmux-ghostrun` is a popup command runner for tmux:
- input popup captures a command and runs it in a hidden ghost session
- output popup shows that command's pane using a native tmux client

## Output mode keys

- `[` previous command (no wrap)
- `]` next command (no wrap)
- `Up` / `Down` scroll output (copy-mode aware)
- `m` switch back to input mode
- `q` or `Esc` close output popup
- output keys are active only while output popup is open

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
