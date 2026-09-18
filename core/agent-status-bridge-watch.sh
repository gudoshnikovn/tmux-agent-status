#!/usr/bin/env bash
# Host-side relay for the `file` transport (see core/agent-status.sh and
# README's "Agent running in a container/VM/remote host" section).
#
# Runs on the machine where the real tmux server lives. Tails a bridge
# file that a hook running inside a container/VM/remote host appends
# status lines to (because it can't reach the tmux socket directly -
# see agent-status.sh for why) and replays each line into tmux via
# agent_status_apply_to_tmux, the same function agent-status.sh calls
# in-process for the default (direct) transport.
#
# Usage: agent-status-bridge-watch.sh <bridge-file> [poll-interval-seconds]
#
# Typically started once from .tmux.conf:
#   run-shell '~/.tmux/plugins/tmux-agent-status/core/agent-status-bridge-watch.sh ~/.cache/tmux-agent-status/bridge-file &'
#
# Polling, not inotify/fswatch: this isn't latency-critical (a status
# transition being a second or two late doesn't matter the way it
# would for, say, a build system), and polling has no platform-specific
# dependency - inotify isn't available on macOS, and pulling in fswatch
# would be a new hard dependency for a feature that's opt-in already.
#
# Checkpointing: <bridge-file>.offset stores the number of lines
# already processed, so a restarted watcher doesn't replay old lines.
# If the bridge file is ever shorter than the recorded offset
# (truncated/rotated/replaced), the offset resets to 0 rather than
# erroring - better to risk replaying a few already-applied lines
# (each is idempotent: it just re-sets the same tmux option) than to
# permanently wedge on a stale offset larger than the file.
#
# Single watcher per bridge file: <bridge-file>.pid records the
# running watcher's pid; a second invocation for the same file exits
# immediately instead of racing the first one over the offset file.
# This is what makes it safe for the `run-shell '... &'` line above to
# re-fire on every `.tmux.conf` reload instead of piling up watchers.

set -euo pipefail

bridge_file="${1:?usage: agent-status-bridge-watch.sh <bridge-file> [poll-interval-seconds]}"
interval="${2:-1}"

CURRENT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./agent-status-apply.sh
source "$CURRENT_DIR/agent-status-apply.sh"

offset_file="${bridge_file}.offset"
pid_file="${bridge_file}.pid"

if [ -f "$pid_file" ]; then
    existing_pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
        exit 0
    fi
fi
echo "$$" > "$pid_file"
cleanup() { rm -f "$pid_file" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

mkdir -p "$(dirname "$bridge_file")" 2>/dev/null || true
touch "$bridge_file"

offset=0
if [ -f "$offset_file" ]; then
    offset="$(cat "$offset_file" 2>/dev/null || echo 0)"
fi
case "$offset" in ''|*[!0-9]*) offset=0 ;; esac

while true; do
    if tmux has-session 2>/dev/null; then
        total_lines="$(wc -l < "$bridge_file" 2>/dev/null || echo 0)"
        total_lines="${total_lines//[[:space:]]/}"
        [ -z "$total_lines" ] && total_lines=0

        # File got truncated/rotated/replaced - start over rather than
        # sitting wedged on an offset past end-of-file forever.
        [ "$total_lines" -lt "$offset" ] && offset=0

        if [ "$total_lines" -gt "$offset" ]; then
            while IFS= read -r line; do
                [ -z "$line" ] && continue

                pane=""
                status=""
                tool=""
                for field in $line; do
                    case "$field" in
                        pane=*) pane="${field#pane=}" ;;
                        status=*) status="${field#status=}" ;;
                        tool=*) tool="${field#tool=}" ;;
                    esac
                done

                [ -z "$pane" ] && continue
                agent_status_apply_to_tmux "$pane" "$status" "$tool"
            done < <(sed -n "$((offset + 1)),${total_lines}p" "$bridge_file")

            offset="$total_lines"
            printf '%s' "$offset" > "$offset_file"
        fi
    fi

    sleep "$interval"
done
