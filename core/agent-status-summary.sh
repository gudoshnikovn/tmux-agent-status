#!/usr/bin/env bash
# Two jobs, both re-run on every tmux status-line recompute:
#
# 1. Crash/liveness sweep: any pane whose @agent_status is non-empty
#    and whose @agent_status_tool no longer matches that tool's
#    adapters/<tool>/process-pattern (i.e. the tool's process is no
#    longer the pane's foreground command - it exited, crashed, or the
#    shell took back control) gets its status cleared. This is a
#    crash/interrupt safety net for every adapter, not a wall-clock
#    idle timeout: a pane whose tool is still the foreground process
#    keeps whatever status it last reported, no matter how long a
#    single tool call or turn takes. Deliberately runs even when the
#    summary display below is turned off (@agent_status_summary off)
#    - it's a correctness fix, not a UI feature.
#
# 2. Persistent status-line summary: counts of panes across all
#    sessions in each state, e.g. "⏳2 ⚙️1 ✅3". Empty output when
#    nothing's active, so it doesn't leave a stray gap in status-right.
#
# Invoked as a `#()` command substitution from status-right - tmux
# recalculates those on its own status-interval, and also immediately
# on `tmux refresh-client` (which agent-status.sh already calls on
# every hook-driven transition), so both jobs stay live without a
# separate timer or background process.

set -euo pipefail

CURRENT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ROOT="$(dirname "$CURRENT_DIR")"

if ! tmux has-session 2>/dev/null; then
    exit 0
fi

# --- 1. Crash/liveness sweep -----------------------------------------

sweep_rows="$(tmux list-panes -a -F '#{pane_id}	#{@agent_status}	#{@agent_status_tool}	#{pane_current_command}' 2>/dev/null || true)"

while IFS=$'\t' read -r pane_id status tool current_command; do
    [ -z "$status" ] && continue
    [ -z "$tool" ] && continue

    pattern_file="$PLUGIN_ROOT/adapters/$tool/process-pattern"
    [ -f "$pattern_file" ] || continue
    pattern="$(cat "$pattern_file")"
    [ -z "$pattern" ] && continue

    if ! printf '%s' "$current_command" | grep -Eq "$pattern"; then
        TMUX_PANE="$pane_id" "$CURRENT_DIR/agent-status.sh" clear >/dev/null 2>&1 || true
    fi
done <<< "$sweep_rows"

# --- 2. Persistent summary --------------------------------------------

summary_enabled="$(tmux show-option -gqv @agent_status_summary 2>/dev/null || true)"
[ "$summary_enabled" = "off" ] && exit 0

rows="$(tmux list-panes -a -F '#{@agent_status}' 2>/dev/null || true)"

waiting="$(printf '%s\n' "$rows" | grep -c '^waiting$' || true)"
working="$(printf '%s\n' "$rows" | grep -c '^working$' || true)"
done_count="$(printf '%s\n' "$rows" | grep -c '^done$' || true)"

out=""
[ "$waiting" -gt 0 ] && out="${out}⏳${waiting} "
[ "$working" -gt 0 ] && out="${out}⚙️${working} "
[ "$done_count" -gt 0 ] && out="${out}✅${done_count} "

printf '%s' "$out"
