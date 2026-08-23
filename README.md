# tmux-agent-status

See at a glance which tmux pane running an AI coding agent (Claude
Code, Hermes, ...) is waiting on you and which one just finished —
across every session and window — and jump straight to it.

## Supported tools

- [Claude Code](https://github.com/anthropics/claude-code) ([hooks docs](https://code.claude.com/docs/en/hooks))
- [Hermes](https://github.com/nousresearch/hermes-agent) ([hooks docs](https://hermes-agent.nousresearch.com/docs/user-guide/features/hooks))

Support for a new tool is just a new `adapters/<tool>/` directory —
see "Adding a new tool" below.

## What it does

- **Picker**: `prefix + j` opens a popup listing every active agent
  pane (working, waiting, or just done) across *all* tmux sessions
  (via [`fzf`](https://github.com/junegunn/fzf)), sorted
  needs-your-input-first, jump to any of them in one keystroke.
- **Status-line summary**: a persistent `⏳2 ⚙️1 ✅3`-style counter
  prepended to `status-right`, so you can see there's something to
  check without opening the picker.
- **Notifications**: a transient tmux popup and (on macOS) a
  notification-center alert when a pane starts waiting on you or
  finishes, so you notice even if you're looking at a different pane.
  Optional sound alert too.
- **Extensible**: support for a new tool is a new `adapters/<tool>/`
  directory (detection + hook installation) — the core picker/summary
  logic is tool-agnostic and never needs to change. See "Adding a new
  tool" below.

## Requirements

- [`fzf`](https://github.com/junegunn/fzf) (picker)
- Per adapter you use:
  - Claude Code: `jq`, Claude Code CLI
  - Hermes: `python3` with `pyyaml`, or `yq`, and the Hermes CLI

## Install

### Via TPM (recommended)

Add to `~/.tmux.conf`:

```tmux
set -g @plugin 'gudoshnikovn/tmux-agent-status'
```

Then `prefix + I` to install. This also detects which supported tools
are present on your machine and merges the required hooks into each
one's own config automatically (additive — it won't touch any hooks
you already have configured).

### Manual

```sh
git clone https://github.com/gudoshnikovn/tmux-agent-status.git ~/.tmux/plugins/tmux-agent-status
echo "run-shell ~/.tmux/plugins/tmux-agent-status/tmux/agent-status.tmux" >> ~/.tmux.conf
tmux source ~/.tmux.conf
```

## Configuration

Two ways to configure this, and they compose freely - use either or both:

### Config file

Copy [`config.example`](config.example) to
`~/.config/tmux-agent-status/config` (or point `$TMUX_AGENT_STATUS_CONFIG`
at a different path) and uncomment what you want to change:

```
pick_key = j
summary = on
notify_sound = off
```

A value here only takes effect if the same option isn't already set via
`set -g @agent_status_<key>` in `.tmux.conf` - an explicit `set -g`
always wins, no matter which one loads first.

### `.tmux.conf`

Set these *before* the plugin line:

```tmux
set -g @agent_status_pick_key 'j'          # prefix + j by default

set -g @agent_status_summary 'off'         # disable the status-right counter
set -g @agent_status_notify 'off'          # disable the transient tmux popup
set -g @agent_status_notify_duration '3000'    # ms the tmux popup stays up
set -g @agent_status_notify_system 'off'   # disable the macOS notification
set -g @agent_status_notify_sound 'on'     # enable a sound on waiting/done (off by default)
set -g @agent_status_notify_sound_file '/System/Library/Sounds/Glass.aiff'
```

### Full option reference

| Config file key | `.tmux.conf` option | Default | Meaning |
|---|---|---|---|
| `pick_key` | `@agent_status_pick_key` | `j` | Key for `prefix + <key>` picker popup |
| `summary` | `@agent_status_summary` | `on` | Status-right `⏳2 ⚙️1 ✅3` counter |
| `notify` | `@agent_status_notify` | `on` | Transient tmux popup on waiting/done |
| `notify_duration` | `@agent_status_notify_duration` | `3000` | ms the tmux popup stays up |
| `notify_system` | `@agent_status_notify_system` | `on` if `osascript` exists | macOS notification-center alert |
| `notify_sound` | `@agent_status_notify_sound` | `off` | Sound on waiting/done |
| `notify_sound_file` | `@agent_status_notify_sound_file` | `/System/Library/Sounds/Glass.aiff` | Sound file to play |

## How it works

Every supported tool's hooks call `core/agent-status.sh <status>
--tool <name>`, which writes per-pane tmux user options
(`@agent_status`, `@agent_status_tool`) using `$TMUX_PANE`.
`core/agent-picker.sh` / `core/agent-status-summary.sh` scan
`@agent_status` across all panes/sessions for the popup picker and the
status-line counter.

For Claude Code specifically, five hooks are wired (`UserPromptSubmit`,
`PreToolUse`, `PermissionRequest`, `Notification`/`idle_prompt`,
`Stop`, plus a few more edge cases) — the full reasoning for each is in
CLAUDE.md, since it was non-obvious and previously got it wrong twice.

## Crash / interrupt recovery

If a tool's process dies or gets interrupted without firing a
"turn ended" hook, its pane could otherwise stay stuck on a stale
`working`/`waiting` status forever. Every adapter gets a shared
safety net for this: `core/agent-status-summary.sh` re-checks, on every
status-line recompute, whether each pane's foreground process
(`#{pane_current_command}`) still matches that tool's
`adapters/<tool>/process-pattern`; if it doesn't (the tool exited and
the shell took back over, or crashed), the status is cleared. This is
**not** a timeout — a pane that's genuinely still running a long tool
call keeps its `working` status for as long as that takes, since the
sweep only looks at whether the process is still there, never at how
long it's been there.

## Adding a new tool

Add a directory `adapters/<tool>/` with three files:

- `detect.sh` — no args, exit 0 if the tool looks usable on this
  machine (e.g. a binary on `PATH`), exit 1 otherwise.
- `install-hooks.sh` — idempotent, additive: registers hooks in that
  tool's own native config format, each one invoking
  `core/agent-status.sh <working|waiting|done|clear> --tool <tool>`.
- `process-pattern` — a single-line regex matched against
  `#{pane_current_command}`, used only by the crash/liveness sweep
  above.

`tmux/agent-status.tmux` picks up any `adapters/*/` directory
automatically on every `tmux source-file` — no core changes needed.

## Uninstall

Remove the `@plugin` line, then remove the hook entries pointing at
`agent-status.sh` from each tool's own config (`~/.claude/settings.json`
for Claude Code, `~/.hermes/config.yaml` for Hermes).
