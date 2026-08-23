# tmux-agent-status

tmux plugin: tracks what the AI coding agent (Claude Code, Hermes, ...)
running in each pane is doing (working / waiting for you / idle), and
gives a `prefix + j` fzf popup to jump to any such pane across all
sessions, plus a persistent status-line counter.

Read `README.md` for the user-facing install/config story. This file
is for whoever (human or Claude) comes back to change the code. See
`docs/superpowers/specs/2026-08-20-multi-tool-adapters-design.md` for
the full design reasoning behind the core/adapter split below — this
file documents the resulting code, that one documents *why* it's split
this way and what alternatives were rejected.

## Files

```
core/
  agent-status.sh          # generic reporter: writes @agent_status + does the tmux side-effects
  agent-picker.sh          # prefix+j popup: lists panes, fzf-picks, jumps
  agent-status-summary.sh  # #() status-right widget: crash sweep + counts panes per state
  load-config.sh           # fills @agent_status_* defaults from ~/.config/tmux-agent-status/config
adapters/
  claude-code/
    detect.sh                # exit 0 if Claude Code looks usable on this machine
    install-hooks.sh         # merges our hook entries into ~/.claude/settings.json
    process-pattern          # regex for the crash/liveness sweep
  hermes/
    detect.sh
    install-hooks.sh         # merges shell hooks into ~/.hermes/config.yaml
    process-pattern
tmux/
  agent-status.tmux        # real entry point: status-right wiring, keybind, adapter loop
agent_status.tmux          # root-level shim - see below
```

**`agent_status.tmux` at the repo root is not a duplicate — it's required for TPM.**
TPM's `source_plugins.sh` globs `*.tmux` only directly in a plugin's
root directory (`$plugin_path*.tmux`, no subdirectory recursion) when
handling `@plugin '...'` entries. The actual logic lives in
`tmux/agent-status.tmux` (grouped with `core/`/`adapters/` as the
"tmux side" of the split); the root shim just `exec`s it. Verified by
tracing TPM's own `scripts/source_plugins.sh` and reproducing the
failure: with only `tmux/agent-status.tmux` present, `@plugin
'gudoshnikovn/tmux-agent-status'` silently sourced nothing (no error,
counter/keybind just never appeared) - the manual `run-shell
'.../tmux/agent-status.tmux'` install path some users may still have
never hit this because it names the full path directly. Don't remove
the root shim or move `tmux/agent-status.tmux`'s logic back into it
without re-testing the actual `@plugin` flow (a fresh `git clone` +
TPM install), not just manually sourcing the file - that's what let
this slip through once already.

**Core is tool-agnostic. Adapters are the only tool-specific code.**
Nothing under `core/` parses any tool's native hook payload or knows
its event names — it only reads/writes the tmux pane user option
`@agent_status` (`working`/`waiting`/`done`/``) and
`@agent_status_tool` (which adapter set it, display-only). Adding
support for a new tool means adding `adapters/<tool>/` with the three
files above; `core/` and `tmux/agent-status.tmux` never change for
that.

Data flow: a tool's native hook fires → its adapter's registered
command calls `core/agent-status.sh <status> --tool <name>` → that
writes `@agent_status`/`@agent_status_tool` on `$TMUX_PANE` →
`agent-status-summary.sh` reads `@agent_status` across `tmux list-panes
-a` to render the status-right counter, and `agent-picker.sh` reads it
the same way for the popup.

## Adapter contract

Every `adapters/<tool>/` directory must provide exactly these three
files, each with no dependency on the others beyond the shared
`core/agent-status.sh` call:

- `detect.sh` — no args, no side effects, exit 0 if the tool looks
  usable on this machine (binary on `PATH`, config dir exists, etc.),
  exit 1 otherwise. Called by `tmux/agent-status.tmux` on every
  `tmux source-file`/plugin load.
- `install-hooks.sh` — idempotent, additive: registers hooks in that
  tool's own native format, each one invoking
  `core/agent-status.sh <working|waiting|done|clear> --tool <tool-dir-name>`.
  Must tolerate being run on every reload without accumulating
  duplicate entries (see the Claude Code adapter's dedup strategy
  below — copy that pattern for new adapters).
- `process-pattern` — a single-line regex matched against
  `#{pane_current_command}`, used only by the crash/liveness sweep in
  `core/agent-status-summary.sh` (see below). Get this wrong (too
  broad or too narrow) and the sweep either never fires or fires while
  the tool is still legitimately running — but it never affects
  `working`/`waiting`/`done` correctness while the process is alive,
  only how fast a genuinely-dead pane gets cleared.

`tmux/agent-status.tmux` discovers adapters by globbing
`adapters/*/` — there is no registry file to update.

## Core protocol: `agent-status.sh`

```
core/agent-status.sh <working|waiting|done|clear> [--tool <name>]
```

Reads `$TMUX_PANE` from the inherited environment (the adapter's
responsibility to ensure it's set — true automatically for any tool
invoked from a shell inside a tmux pane), drains stdin (so a tool that
pipes a JSON hook payload doesn't see a broken pipe), and writes:

- `@agent_status` — the status itself.
- `@agent_status_updated_at` — epoch seconds of this write. Currently
  only for observability (e.g. "how long has this pane said waiting");
  the crash/liveness sweep deliberately does **not** key off this (see
  "Crash/liveness sweep" below for why a wall-clock timeout was
  rejected).
- `@agent_status_tool` — only if `--tool` was passed. Display-only
  (the picker could show it); omitting it (e.g. on a bare `clear` call)
  leaves the previous value in place rather than blanking it.

## Crash/liveness sweep (not a timeout)

Every tool has some gap where its "turn ended" hook doesn't fire —
Claude Code's is user-interrupt (`Stop` doesn't fire on Escape/Ctrl-C);
Hermes doesn't even have Claude's `idle_prompt`-style self-healing
notification at all (verified against `EventHooks_Hermes.pdf` — no
"still idle after N seconds" event exists in any of its four hook
systems). Something has to un-stick a pane that's left showing a stale
`working`/`waiting` forever.

**A wall-clock idle timeout was considered and rejected**: a
long-running tool call (a slow build, a long generation) can
legitimately hold `working` for many minutes with zero intervening
hook fires. A timeout can't tell "still working, just slow" apart from
"the process died and nothing told us" — it would misfire on exactly
the panes doing real, long-running work.

**What's implemented instead**: `core/agent-status-summary.sh` runs a
sweep, on every status-line recompute (see "why no separate timer"
below), over every pane with a non-empty `@agent_status`. If
`@agent_status_tool` is set and the pane's `#{pane_current_command}` no
longer matches that tool's `adapters/<tool>/process-pattern` — the
tool's process is no longer the pane's foreground command, i.e. it
exited, crashed, or the shell took back over — the status is cleared
via `agent-status.sh clear` (invoked with `TMUX_PANE` overridden to the
target pane's `#{pane_id}`, since the sweep itself doesn't run inside
that pane). Panes where `@agent_status_tool` was never set (e.g. a
manually-set test status, or an adapter that doesn't pass `--tool`)
are skipped entirely — nothing to compare against.

This runs even when the visible counter is disabled
(`@agent_status_summary off`) — it's a correctness fix, not a display
feature, so it must not depend on the display being on. It applies to
every adapter, not just ones lacking a native self-heal — Claude Code
gets it too, as a second safety net alongside `idle_prompt` (both
converge on the same outcome, no conflict).

If you touch this logic, verify with the "sleep-as-a-fake-tool" recipe
in "Manual end-to-end test" below.

## The Claude Code adapter: hook wiring — why these specific events

This was **not** guessed — the exact semantics below were verified
against the official Claude Code hooks reference (fetched as a PDF,
`code.claude.com/docs/en/hooks`) after two rounds of getting it wrong
empirically. Don't revert to something that "seems more obvious"
without re-reading that reference; several tempting options are wrong
in non-obvious ways.

The `Elicitation`/`ElicitationResult`/`StopFailure`/`SessionEnd` rows
were added later, against a re-fetched copy of the same PDF
(`hooks_docs_claude.pdf`, since removed from the repo root — see
"Known limitations" — but was pulled 2026-08-20) - the event list grows
between Claude Code versions (that pull also showed `TaskCreated`,
`TeammateIdle`, `WorktreeCreate`, `PreCompact`, and others we
deliberately did NOT hook - see "Events considered and rejected"
below). If you're auditing this table again, re-pull the PDF rather
than trusting this list to be exhaustive forever.

| Hook event | Matcher | Status set | Why |
|---|---|---|---|
| `UserPromptSubmit` | — | `working` | You just sent a message. |
| `PreToolUse` | — | `working` | Fires right before a tool call. **Does not re-fire** after a permission prompt for that same call is resolved — see the gotcha below. |
| `PermissionRequest` | — | `waiting` | Fires exactly when the permission dialog is shown. Deliberately **not** using `Notification`'s `permission_prompt` type for this — `PermissionRequest` is the dedicated event for it and doesn't require string-matching a notification payload. |
| `PostToolUse` | — | `working` | Fires right after a tool finishes running. This is what actually clears `waiting` back to `working` once you approve a permission prompt and the tool executes — there's no dedicated "permission resolved" hook. |
| `Notification` | `idle_prompt` only | `done` | `Notification` fires for many unrelated things (`auth_success`, `elicitation_*`, `agent_completed`, ...). We only care about `idle_prompt` ("Claude is waiting for your input", fires ~60s after going idle). Matching on `""` (all types) was the v1 bug: it repainted an already-finished, nothing-pending pane back to yellow every ~60s. |
| `Stop` | — | `done` | Normal end of turn, back to idle. |
| `Elicitation` | — | `waiting` | Dedicated event (as of a later Claude Code version) for an MCP tool asking for structured input mid-call. Same urgency as `PermissionRequest` - deliberately hooked directly instead of waiting on `Notification`'s `elicitation_dialog` type, for the same reason `PermissionRequest` is used over `Notification`'s `permission_prompt`: it's immediate, no ~60s lag. |
| `ElicitationResult` | — | `working` | You answered the elicitation. Mirrors `PostToolUse`'s job of clearing `waiting`. |
| `StopFailure` | — | `done` | Turn ended via API error (`rate_limit`, `overloaded`, `billing_error`, etc), not a normal response. `Stop` does not fire in this case - same class of gap as the interrupt gotcha below, except there's no `idle_prompt` fallback lag tradeoff here worth accepting since this is just as easy to hook directly. |
| `SessionEnd` | — | `clear` (`""`) | The Claude Code *session* ended (`/exit`, `logout`, etc) - as opposed to a turn ending. Without this, a tmux pane that outlives the Claude Code process sits on whatever color it last had, forever. |

### The "waiting doesn't clear" gotcha (PreToolUse vs PostToolUse)

Earlier revisions of this doc assumed `PreToolUse` fires a second time
right after a permission prompt is approved, and relied on that to
flip `waiting` back to `working`. **Empirically false** — instrumented
`core/agent-status.sh` (then `hooks/claude-status.sh`) with a debug log
(`hook_event_name`/timestamp/pid per invocation) and confirmed
`PreToolUse` fires exactly once per `tool_use_id`, *before* the
permission check, never again after approval. With only the events in
the original table, a pane could sit on `waiting` for as long as
Claude had no more tool calls to make (i.e. until it finished writing
its text response and `Stop` fired) — sometimes tens of seconds. Fixed
by adding `PostToolUse -> working`, which reliably fires immediately
after the approved tool actually executes, regardless of whether
another `PreToolUse` follows it. If you're ever tempted to touch this
event wiring again, re-verify by instrumenting the hook script rather
than trusting the hooks reference doc alone — the doc's ordering claim
here didn't hold up.

### Events considered and rejected

From the full event list in `hooks_docs_claude.pdf`, these were looked
at and deliberately left unhooked - noted so nobody re-adds them
without re-deriving why:

- **`SubagentStart`/`SubagentStop`** - fire for Task-tool subagents
  running *inside* an already-`working` top-level turn. Hooking these
  would flip the pane's status based on subagent lifecycle while the
  top-level agent is still doing exactly what `working` already says.
- **`TeammateIdle`** - specific to the multi-agent "agent team"
  feature, not the single-Claude-per-pane model this plugin assumes.
- **`PermissionDenied`** - when you deny a permission prompt, Claude
  doesn't get stuck: it either calls another tool (`PreToolUse` fires,
  clears `waiting`) or finishes the turn (`Stop` fires). No gap to
  patch here the way `StopFailure` had one.
- **`WorktreeCreate`/`WorktreeRemove`/`FileChanged`/`CwdChanged`/
  `ConfigChange`/`PreCompact`/`PostCompact`/`InstructionsLoaded`/etc** -
  none of these represent "is Claude working, waiting on you, or idle";
  they're orthogonal session/environment events.

### The interrupt gotcha

**`Stop` does not fire if the user interrupts Claude (Escape/Ctrl-C).**
This is explicit in the docs: *"Stop: Запускается при завершении
ответа основного агента Claude Code. Не запускается, если остановка
произошла из-за прерывания пользователя."* There is no separate
"Interrupt" hook event to catch this case instead.

Consequence: if you interrupt Claude mid-turn, nothing tells us to
leave `working`. The fix in place is that the `idle_prompt` Notification
fires **regardless of why** Claude went idle (interrupt included), so
within ~60s an interrupted pane self-heals from `working` to `done`
(and, as a second-layer backstop, the crash/liveness sweep above would
also eventually clear it if the process actually exited). This is a
deliberate tradeoff (up to ~60s of stale color while the process is
still alive) rather than a missed case — there is currently no way to
detect "interrupted" any faster with documented hooks. If Claude Code
ever adds a dedicated interrupt/cancel hook, switch to it and drop this
workaround.

### Notification's full `notification_type` list (for reference)

`permission_prompt`, `idle_prompt`, `auth_success`, `elicitation_dialog`,
`elicitation_complete`, `elicitation_response`, `agent_needs_input`,
`agent_completed`. Only `idle_prompt` is currently hooked; the others
were considered and rejected for this use case (see table above).

## The Hermes adapter: event mapping and open gaps

Based on `EventHooks_Hermes.pdf` (pulled 2026-08-20, since removed
from the repo root — see "Known limitations"). Hermes has four
separate hook systems (gateway hooks, plugin hooks, shell hooks,
outbound webhooks); only **shell hooks** are usable here, since they're
the only ones that run as plain subprocesses invocable from a plugin
that doesn't live inside Hermes's own process. They're declared under a
`hooks:` block in `~/.hermes/config.yaml` (YAML, not JSON).

| Hermes event | Status set |
|---|---|
| `pre_llm_call` | `working` (fires once per turn, before the tool loop — closest analog to `UserPromptSubmit`) |
| `pre_tool_call` | `working` (direct analog of `PreToolUse`) |
| `pre_approval_request` | `waiting` |
| `post_tool_call` | `working` (direct analog of `PostToolUse`) |
| `post_approval_response` | `working` (belt-and-suspenders alongside `post_tool_call` for clearing `waiting`, since there's no single event guaranteed to fire in every approval-resolution code path) |

**Deliberately not wired, pending verification:**

- `on_session_end` — documented as firing "at the very end of every
  `run_conversation()` call". It's unverified whether that means
  end-of-process (→ `clear`, like Claude's `SessionEnd`) or
  end-of-turn (→ overlaps with `Stop`'s job). Wiring it wrong would
  either leave panes stuck without a `clear` path, or clear
  mid-conversation. **Verify empirically** with `hermes hooks test
  on_session_end` (or a debug-logging throwaway shell hook — same
  technique used above for Claude Code's `PreToolUse`/`PostToolUse`)
  before wiring it. Until then, Hermes panes rely solely on the
  crash/liveness sweep to clear a stale status once the `hermes`
  process actually exits.
- Any `StopFailure` analog — Hermes's closest events
  (`api_request_error`, `transform_api_error_classification`) fire per
  failed *attempt* mid-turn (which may still retry), not per
  turn-abandoned. A Hermes pane that fails via API error keeps showing
  `working` until the crash/liveness sweep notices the process exited,
  or the next turn starts. Documented gap, not a guess dressed up as a
  mapping.

**Consent requirement**: Hermes shell hooks require either an
interactive first-use approval (persisted to
`~/.hermes/shell-hooks-allowlist.json`) or a non-interactive opt-in
(`HERMES_ACCEPT_HOOKS=1` / `--accept-hooks` / `hooks_auto_accept: true`
in config.yaml), or they silently never register.
`adapters/hermes/install-hooks.sh` deliberately does **not** set
`hooks_auto_accept` itself — that flag is global and would weaken
Hermes's consent model for every shell hook, not just this plugin's.
It prints a reminder to run `hermes` once and approve the prompt
instead. Don't "fix" this by auto-setting the flag without discussing
the tradeoff first.

**YAML editing**: `install-hooks.sh` prefers `python3` + `pyyaml`
(likely present since Hermes itself needs Python for its own
`handler.py`-based hooks), falls back to `yq` (mikefarah/yq syntax) if
present, and otherwise prints the YAML block to add manually rather
than failing the tmux reload — same graceful-degradation shape as the
Claude Code adapter's `jq`-missing path.

## Forced redraw + transient notification (agent-status.sh side effects)

Two things happen in `agent-status.sh` beyond writing `@agent_status`:

1. **`tmux refresh-client`** after every write. The status-right `#()`
   summary is a global format, but tmux does **not** recompute it just
   because the underlying option changed — only on the next natural
   redraw (focus change, pane output, `status-interval` timer, etc).
   Without forcing this, a transition set by `PostToolUse` (right after
   you approve a permission prompt) could sit stale in the counter
   until something unrelated forced a redraw. No polling needed; the
   hook already fires on every transition, so redraw-on-write is
   sufficient.

2. **`tmux display-message`** on a real transition into `waiting` or
   `done` (never `working` — that would fire on every tool call and
   turn into noise). "Real transition" means the previous
   `@agent_status` value (read via `show-option` before overwriting)
   differs from the new one — this is what stops the recurring
   `idle_prompt` Notification (fires every ~60s while still idle) from
   re-popping the same message repeatedly. Opt out with
   `set -g @agent_status_notify off`; duration is
   `@agent_status_notify_duration` in ms (default 3000).

## System notification, sound, and the persistent status-line summary

Three more things layered on top of the transient `tmux display-message`:

- **macOS notification** (`osascript`, gated by `@agent_status_notify_system`,
  default on if `osascript` exists): fires on the same real
  waiting/done transition as the tmux message. The reason it exists
  *in addition to* the tmux message: tmux dismisses `display-message`
  on **any keypress anywhere in the session**, not just in the target
  pane. If you're actively typing in another pane when it fires, it
  can flash and vanish before you register it. The OS notification
  lives outside tmux entirely, so it isn't affected. Session/window/pane
  names get shell-escaped for the embedded AppleScript string
  (`sed 's/\\/\\\\/g; s/"/\\"/g'`) since they're user-controlled.
- **Sound** (`afplay`, gated by `@agent_status_notify_sound`, **default
  off** — deliberately opt-in since it fires on every transition and
  gets old fast unlike a one-time popup). File configurable via
  `@agent_status_notify_sound_file` (default
  `/System/Library/Sounds/Glass.aiff`).
- **Persistent status-line summary** (`core/agent-status-summary.sh`,
  prepended to `status-right` by `agent-status.tmux`, gated by
  `@agent_status_summary`, default on): counts panes in each state
  across all sessions (`⏳2 ⚙️1 ✅3`), always visible instead of a
  transient popup. Uses a **baseline-capture-once trick** via
  `@agent_status_base_status_right`: captured once, read only if unset,
  so re-sourcing `.tmux.conf` doesn't re-capture our own
  already-prepended output as the new "base" and duplicate it.

Why this doesn't need its own polling loop: tmux recalculates `#()`
command substitutions in the status line on its own `status-interval`
timer, but a plain `tmux refresh-client` (already called by
`agent-status.sh` on every hook-driven transition, for the redraw fix
above) also forces the client's full screen — status line included —
to redraw immediately. One refresh call covers the counter *and* the
crash/liveness sweep (which lives in the same script, see above).

## install-hooks.sh: how the Claude Code merge works

`adapters/claude-code/install-hooks.sh` edits `~/.claude/settings.json`
(or `$CLAUDE_SETTINGS_FILE` for testing) with `jq`, and must stay
**additive** — it runs on every tmux config reload
(`tmux/agent-status.tmux` calls every detected adapter's
`install-hooks.sh` unconditionally), so it has to be idempotent against
a settings file that may have unrelated hooks from other tools.

The dedup strategy: for each event we manage, strip *any* existing
entry whose `hooks[0].command` starts with our script's absolute path
(`is_ours` in the jq filter), regardless of matcher, then re-add the
current desired entry/entries for that event. This means changing
which matcher or command we use for an event (like the `idle_prompt`
fix) migrates existing installs cleanly instead of leaving stale
duplicates alongside the new one — this bit was gotten wrong once
before matcher-aware stripping was added; test any future change to
this logic against a settings file from *before* the change, not just
a fresh one. The Hermes adapter's Python merge path uses the same
dedup-by-command-prefix idea, adapted to YAML lists.

To test changes to this script without touching your real config:

```sh
export CLAUDE_SETTINGS_FILE=/tmp/test-settings.json
echo '{}' > "$CLAUDE_SETTINGS_FILE"
./adapters/claude-code/install-hooks.sh
jq '.hooks' "$CLAUDE_SETTINGS_FILE"
./adapters/claude-code/install-hooks.sh   # run again, diff should be empty (idempotent)
```

To test the Hermes adapter similarly:

```sh
export HERMES_CONFIG_FILE=/tmp/test-hermes-config.yaml
./adapters/hermes/install-hooks.sh
cat "$HERMES_CONFIG_FILE"
./adapters/hermes/install-hooks.sh   # run again, diff should be empty (idempotent)
```

## Config file: `load-config.sh`

`tmux/agent-status.tmux` calls `core/load-config.sh` as its very first
step, before any `tmux_option` read. It fills in `@agent_status_<key>`
tmux user options from a plain `key = value` file
(`~/.config/tmux-agent-status/config` by default, overridable via
`$TMUX_AGENT_STATUS_CONFIG`) — this is an alternative to writing
`set -g @agent_status_<key> value` lines directly in `.tmux.conf`, for
people who'd rather edit a dedicated file (and potentially version/sync
it separately from their `.tmux.conf`).

**Format was deliberately kept to flat `key = value`, not JSON/YAML.**
Every other option-reading script in this repo (`agent-status.sh`,
`agent-status-summary.sh`, the `tmux_option` helper in
`agent-status.tmux` itself) is plain POSIX-ish bash with zero hard
dependencies — `jq`/`yq`/`pyyaml` only show up as *adapter*
dependencies (`install-hooks.sh`, gated behind graceful fallback if
missing). Requiring `jq` just to load core config would add a hard
dependency to a path that currently has none, for a feature that's
optional in the first place. If a future request needs nested/
structured config, revisit this tradeoff explicitly rather than
reaching for `jq` by default.

**Precedence: file fills gaps, never overrides.** Before writing
`@agent_status_<key>`, `load-config.sh` checks
`tmux show-option -gqv @agent_status_<key>` and skips the line if it's
already non-empty. This is the same "capture baseline only if unset"
trick `agent-status.tmux` uses for `@agent_status_base_status_right`
(see "System notification, sound, and the persistent status-line
summary" above) — applied here so the config file and `.tmux.conf`
`set -g` lines compose regardless of which runs first in `.tmux.conf`'s
source order. Do **not** change this to an unconditional
`tmux set-option -g` — that would make the file able to stomp an
explicit `set -g` written *before* the plugin's `run-shell` line, which
breaks the normal tmux mental model of "later `set` in `.tmux.conf`
wins."

`config.example` in the repo root is the canonical list of keys this
loads — keep it in sync with the option tables in `agent-status.sh`,
`agent-status.tmux`, and `agent-status-summary.sh` if a new tunable is
ever added to any of them.

## Path resolution gotcha

All adapter scripts and `agent-status.tmux` resolve their own directory
with `cd -P ... && pwd -P` (physical path, symlinks resolved), **not**
plain `cd && pwd`. This plugin is typically symlinked into
`~/.tmux/plugins/tmux-agent-status` for TPM while the actual repo
lives elsewhere (e.g. `~/Programming/tmux-agent-status`). With a
logical (non-`-P`) resolution, invoking a script via the symlink vs.
the real path produces two different absolute path strings for the
same file — which broke `install-hooks.sh`'s dedup (it registers hooks
keyed by absolute script path) and caused every hook to fire twice. If
you ever add another script that needs its own path (e.g. a new
adapter's `install-hooks.sh`, which needs `core/agent-status.sh`'s
absolute path), resolve it the same way — note the adapters are one
directory deeper than the old flat `scripts/`, so it's
`cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P` to reach the
plugin root, not `/..`.

## Border coloring was removed — don't re-add it casually

An earlier version of this plugin colored `pane-border-style` /
`pane-active-border-style` by `@agent_status`, with a
baseline-capture-once trick (`@agent_status_base_border_style` /
`@agent_status_base_active_border_style`) so it wouldn't stomp a theme
plugin (Catppuccin etc.) loaded earlier via TPM. It was deliberately
removed: tmux only draws a border at all for windows with 2+ panes or
with `pane-border-status` enabled, and in the common one-agent-per-
window layout the status-right counter + `prefix+j` picker already
cover "what's happening" and "jump there" without needing a second,
narrower-scoped signal that only helps when several panes of one
window are on screen simultaneously.

`agent-status.tmux` still runs a one-time migration on every load:
if `pane-border-style`/`pane-active-border-style` still contain our
old `@agent_status` conditional (from a pre-removal install), it's
restored to the captured baseline (or unset if there wasn't one) and
the now-unused `@agent_status_base_*` options are cleared. If you're
tempted to re-add border coloring, make it opt-in via a
`@agent_status_border` toggle rather than always-on — that was the
actual complaint that got it removed.

### Testing the config file

```sh
export TMUX_AGENT_STATUS_CONFIG=/tmp/test-agent-status-config
cat > "$TMUX_AGENT_STATUS_CONFIG" <<'EOF'
summary = off
notify_sound_file = /tmp/whatever.aiff
EOF
tmux set-option -gu @agent_status_summary            # ensure clean slate
tmux set-option -gu @agent_status_notify_sound_file
core/load-config.sh
tmux show-option -gqv @agent_status_summary          # -> off
tmux show-option -gqv @agent_status_notify_sound_file # -> /tmp/whatever.aiff

core/load-config.sh                                  # run again, idempotent - values unchanged

tmux set-option -g @agent_status_summary on          # simulate an explicit .tmux.conf override
core/load-config.sh
tmux show-option -gqv @agent_status_summary          # must stay "on" - file must NOT stomp it
```

## Manual end-to-end test (no real agent session needed)

```sh
tmux set-option -p -t $TMUX_PANE @agent_status working
tmux set-option -p -t $TMUX_PANE @agent_status waiting
tmux set-option -p -t $TMUX_PANE @agent_status done
tmux set-option -p -t $TMUX_PANE @agent_status ""
```

Then `prefix + j` from another pane/session should list this pane
whenever its status is `working`/`waiting`/`done` (never on `""`),
sorted `waiting` > `working` > `done`. The status-right counter should
also update immediately (no need to wait for `status-interval`) and,
going into `waiting`/`done` from a different value, flash a
`tmux display-message` naming the pane — but only once per transition,
not on repeats of the same value. Setting the same status twice in a
row should NOT re-flash the message.

### Testing the crash/liveness sweep

Fake a long-running "tool" in a pane and confirm the sweep leaves it
alone while it's alive, then clears it once it exits:

```sh
sleep 999 &
SLEEP_PID=$!
tmux set-option -p -t $TMUX_PANE @agent_status working
tmux set-option -p -t $TMUX_PANE @agent_status_tool claude-code   # process-pattern matches "node|claude", won't match "sleep" - use a throwaway adapter dir or temporarily edit process-pattern to "^sleep$" for this test
core/agent-status-summary.sh   # run the sweep manually; status should NOT clear (process alive, pattern matches)
kill "$SLEEP_PID"
core/agent-status-summary.sh   # run again; status SHOULD now be cleared
tmux show-option -p -t $TMUX_PANE @agent_status   # confirm empty
```

## Known limitations / not-yet-done

- Published at `https://github.com/gudoshnikovn/tmux-agent-status` (MIT
  license). Note the user's own git remote for this repo uses a
  personal SSH host alias (`git@github.gudoshnikovn:...`, configured in
  their `~/.ssh/config` for multi-account auth) — that's local to their
  machine, not something to put in user-facing docs; anyone else clones
  via the normal `github.com` host. The user's own `.tmux.conf` still
  loads the plugin via a local symlink
  (`~/.tmux/plugins/tmux-agent-status` -> the working repo clone), not
  TPM's `@plugin 'gudoshnikovn/tmux-agent-status'` git-clone flow —
  switching to that is a separate step, ask before doing it.
- The reference PDFs (`hooks_docs_claude.pdf`, `EventHooks_Hermes.pdf`)
  used to derive the event tables above are deliberately not tracked in
  this repo (kept local, `.gitignore`d) — re-fetch the current docs
  rather than assuming either event table stays exhaustive forever,
  especially for Hermes, which is a much younger integration here than
  Claude Code's.
- No automated tests; verification so far has been the manual jq/yaml/
  tmux commands documented above, run by hand each time. If this grows,
  consider a small bats/shellspec suite for the adapters' merge logic
  in particular, since that's the part most likely to regress silently
  (wrong dedup = duplicate hook firings, easy to miss).
- Hermes's `on_session_end` ambiguity (see "The Hermes adapter" above)
  is unresolved — it's not wired to anything yet. Resolving it is the
  next natural follow-up once someone can run `hermes hooks test`
  against a real Hermes install.
