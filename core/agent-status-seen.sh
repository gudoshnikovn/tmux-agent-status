#!/usr/bin/env bash
# Marks a finished pane as seen once a focused client is showing it. Runs from
# tmux hooks on every pane/window/session/terminal focus change. @agent_status
# stays "done": the pane keeps its picker row and the sweep still covers it.

set -euo pipefail

changed=""
while IFS=$'\t' read -r flags pane; do
    case "$flags" in *focused*) ;; *) continue ;; esac
    [ "$(tmux show-option -p -qv -t "$pane" @agent_status 2>/dev/null || true)" = "done" ] || continue
    [ -z "$(tmux show-option -p -qv -t "$pane" @agent_status_seen 2>/dev/null || true)" ] || continue
    tmux set-option -p -t "$pane" @agent_status_seen 1 2>/dev/null || true
    changed=1
done < <(tmux list-clients -F '#{client_flags}	#{pane_id}' 2>/dev/null || true)

[ -z "$changed" ] || tmux refresh-client -S 2>/dev/null || true
