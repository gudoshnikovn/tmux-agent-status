#!/usr/bin/env bash
# Generic per-pane status reporter. This is the one stable interface
# any adapter (Claude Code, Hermes, ...) talks to - it knows nothing
# about any particular tool's hook/event system.
#
# Usage: agent-status.sh <working|waiting|done|clear> [--tool <name>]
#
# Reads stdin (an adapter's native hook JSON payload, if any) only to
# drain it; the status value comes from $1. Writes tmux pane user
# options: @agent_status, @agent_status_updated_at (epoch seconds,
# used by the crash/liveness sweep in agent-status-summary.sh), and
# @agent_status_tool (only if --tool was passed - display-only, no
# status logic depends on it, and a bare `clear` call can omit it to
# leave the last-known tool name in place).
#
# Besides writing @agent_status, each invocation also:
#   - forces `tmux refresh-client` so the status-line summary (see
#     agent-status-summary.sh) updates right away instead of waiting
#     for the next unrelated redraw
#   - on a real transition into waiting/done, fires a transient
#     `tmux display-message` so you notice without checking the picker
#     (opt out: `set -g @agent_status_notify off`) - note tmux dismisses
#     this on ANY keypress anywhere, so it can vanish unread if you're
#     typing in another pane at that instant
#   - the same transition can also fire a macOS notification-center
#     alert (survives the keypress problem above since it's outside
#     tmux) via `@agent_status_notify_system` (default: on if osascript
#     exists), and/or a sound via `@agent_status_notify_sound`
#     (default: off - opt in, it's the most intrusive option)

set -euo pipefail

status=""
tool=""

while [ $# -gt 0 ]; do
    case "$1" in
        --tool)
            tool="${2:-}"
            shift 2
            ;;
        *)
            status="$1"
            shift
            ;;
    esac
done

# Drain stdin so the calling tool doesn't see a broken pipe; we don't
# need the JSON payload itself.
cat >/dev/null || true

# Not running inside tmux (or pane already gone) - nothing to report.
if [ -z "${TMUX_PANE:-}" ]; then
    exit 0
fi

if ! tmux has-session 2>/dev/null; then
    exit 0
fi

# Read the previous value before overwriting it - needed below to tell
# a real transition (e.g. "working" -> "waiting") from a same-status
# re-fire, so the transient notification doesn't spam on every re-fire.
prev_status="$(tmux show-option -p -qv -t "$TMUX_PANE" @agent_status 2>/dev/null || true)"

case "$status" in
    working|waiting|done)
        tmux set-option -p -t "$TMUX_PANE" @agent_status "$status" 2>/dev/null || true
        ;;
    clear|*)
        status=""
        tmux set-option -p -t "$TMUX_PANE" @agent_status "" 2>/dev/null || true
        ;;
esac

tmux set-option -p -t "$TMUX_PANE" @agent_status_updated_at "$(date +%s)" 2>/dev/null || true

if [ -n "$tool" ]; then
    tmux set-option -p -t "$TMUX_PANE" @agent_status_tool "$tool" 2>/dev/null || true
fi

# The status-line #() summary is a global format, but tmux does not
# recompute it on every option change - only on the next natural
# redraw (focus change, output, status-interval timer, etc). Force it
# immediately instead of waiting/polling.
tmux refresh-client 2>/dev/null || true

# Transient "psst, look over here" notification: only on a real
# transition into waiting/done (not a same-status re-fire, and not on
# "working" - that would fire on every single tool call). Opt out with
# `set -g @agent_status_notify off`.
notify_enabled="$(tmux show-option -gqv @agent_status_notify 2>/dev/null || true)"
if [ "$notify_enabled" != "off" ] && [ "$status" != "$prev_status" ] && { [ "$status" = "waiting" ] || [ "$status" = "done" ]; }; then
    duration="$(tmux show-option -gqv @agent_status_notify_duration 2>/dev/null || true)"
    [ -z "$duration" ] && duration=3000

    location="$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)"

    case "$status" in
        waiting) icon="⏳ waiting" ;;
        done)    icon="✅ done" ;;
    esac

    tmux display-message -d "$duration" -t "$TMUX_PANE" "$icon: $location" 2>/dev/null || true

    # macOS notification-center alert - unlike the tmux message above,
    # this isn't dismissed by keypresses in the terminal, so it's the
    # one that actually gets noticed while you're typing elsewhere.
    system_notify="$(tmux show-option -gqv @agent_status_notify_system 2>/dev/null || true)"
    if [ "$system_notify" != "off" ] && command -v osascript >/dev/null 2>&1; then
        # Escape backslashes/quotes - session/window/pane names are
        # user-controlled and get embedded in an AppleScript string.
        safe_location="$(printf '%s' "$location" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        osascript -e "display notification \"$safe_location\" with title \"tmux-claude-status\" subtitle \"$icon\"" >/dev/null 2>&1 &
    fi

    # Optional sound - off by default since it fires on every
    # waiting/done transition and can get old fast. Opt in with
    # `set -g @agent_status_notify_sound on`.
    sound_enabled="$(tmux show-option -gqv @agent_status_notify_sound 2>/dev/null || true)"
    if [ "$sound_enabled" = "on" ] && command -v afplay >/dev/null 2>&1; then
        sound_file="$(tmux show-option -gqv @agent_status_notify_sound_file 2>/dev/null || true)"
        [ -z "$sound_file" ] && sound_file="/System/Library/Sounds/Glass.aiff"
        afplay "$sound_file" >/dev/null 2>&1 &
    fi
fi
