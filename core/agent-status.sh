#!/usr/bin/env bash
# Generic per-pane status reporter. This is the one stable interface
# any adapter (Claude Code, Hermes, ...) talks to - it knows nothing
# about any particular tool's hook/event system.
#
# Usage: agent-status.sh <working|waiting|done|clear> [--tool <name>]
#
# Reads stdin (an adapter's native hook JSON payload, if any) only to
# drain it; the status value comes from $1.
#
# Transport: how this reaches the real tmux server, chosen by
# $TMUX_AGENT_STATUS_TRANSPORT (falling back to the tmux global option
# @agent_status_transport, i.e. config-file/`set -g @agent_status_transport`,
# only when the `tmux` binary is actually present - see below for why
# that guard matters) - defaults to "direct" if neither is set:
#
#   - direct (default): call tmux directly, in this same process. Only
#     works when the hook runs in the same OS kernel the tmux server is
#     in - true for a normal local shell, false inside a
#     devcontainer/Docker/WSL2/SSH/CI sandbox even when the tmux
#     socket file is visible via a shared filesystem (a Unix socket is
#     a kernel object, not just bytes on disk - connect() to a bind-
#     mounted socket from a different kernel fails with "no server
#     running").
#   - file: append a line describing this transition to
#     $TMUX_AGENT_STATUS_BRIDGE_FILE (falling back to the tmux global
#     option @agent_status_bridge_file the same way as transport
#     above) instead of touching tmux at all. A separate process,
#     agent-status-bridge-watch.sh, running on the host where tmux
#     actually lives, tails that file and replays each line into tmux.
#     This is the escape hatch for containers/VMs/remote hosts: set
#     both env vars in the container's environment (they must be set
#     explicitly - Docker does not forward host env vars into a
#     container on its own) and point the bridge file at a path shared
#     with the host (a bind mount). See README's "Agent running in a
#     container/VM/remote host" section.
#
# Besides writing @agent_status (direct transport) or a bridge-file
# line (file transport), see agent-status-apply.sh for the rest of the
# side effects (refresh-client, transient notification, macOS alert,
# sound) - identical either way, just applied either inline or by the
# bridge watcher.

set -euo pipefail

CURRENT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./agent-status-apply.sh
source "$CURRENT_DIR/agent-status-apply.sh"

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
# Note this env var must be forwarded explicitly into a
# container/VM/remote host for transport=file to have a pane to target
# - it is not something Docker/SSH pass through on their own.
if [ -z "${TMUX_PANE:-}" ]; then
    exit 0
fi

case "$status" in
    working|waiting|done) ;;
    *) status="" ;;
esac

transport="${TMUX_AGENT_STATUS_TRANSPORT:-}"
if [ -z "$transport" ] && command -v tmux >/dev/null 2>&1; then
    transport="$(tmux show-option -gqv @agent_status_transport 2>/dev/null || true)"
fi
[ -z "$transport" ] && transport="direct"

if [ "$transport" = "file" ]; then
    bridge_file="${TMUX_AGENT_STATUS_BRIDGE_FILE:-}"
    if [ -z "$bridge_file" ] && command -v tmux >/dev/null 2>&1; then
        bridge_file="$(tmux show-option -gqv @agent_status_bridge_file 2>/dev/null || true)"
    fi

    if [ -z "$bridge_file" ]; then
        echo "agent-status.sh: transport=file requires TMUX_AGENT_STATUS_BRIDGE_FILE (or @agent_status_bridge_file) to be set" >&2
        exit 0
    fi

    mkdir -p "$(dirname "$bridge_file")" 2>/dev/null || true
    # Single short line, well under PIPE_BUF - concurrent appends from
    # multiple panes/containers stay atomic without needing a lock.
    printf '%s pane=%s status=%s tool=%s\n' "$(date +%s)" "$TMUX_PANE" "$status" "$tool" >> "$bridge_file" 2>/dev/null || true
    exit 0
fi

# transport = direct
# $TMUX_PANE is just an inherited env var: a detached background
# process (e.g. `claude daemon`, spawned from some pane and outliving
# it) keeps it and would write every one of its own sessions' hooks
# into that unrelated pane. Only trust it if some ancestor process is
# attached to that pane's tty - not our own tty: Claude Code runs hooks
# without a controlling terminal, only the claude process itself has one.
pane_tty="$(tmux display-message -p -t "$TMUX_PANE" '#{pane_tty}' 2>/dev/null || true)"
pid=$$
while :; do
    [ "${pid:-0}" -gt 1 ] || exit 0
    read -r proc_tty ppid < <(ps -o tty=,ppid= -p "$pid" 2>/dev/null) || exit 0
    [ "/dev/$proc_tty" = "$pane_tty" ] && break
    pid="$ppid"
done

agent_status_apply_to_tmux "$TMUX_PANE" "$status" "$tool"
