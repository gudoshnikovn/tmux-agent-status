#!/usr/bin/env bash
# Lists every pane across all tmux sessions that has an agent status
# (needs your input, still working, or just finished) and jumps to the
# one picked in fzf. Also supports dismissing panes from the list
# (ctrl-x) without losing their live status - dismissing just clears
# @agent_status, the same as the crash/liveness sweep's clear path, so
# the pane naturally reappears the next time its adapter fires a hook.

set -euo pipefail

CURRENT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# Foreground processes on any tty that look like a known agent, as "tty<TAB>name".
# Runtimes count by their script: "node /path/to/gemini" is gemini.
running_agents() {
    local names
    names="$(tmux show-option -gqv @agent_status_agents 2>/dev/null || true)"
    [ -n "$names" ] || names="claude codex gemini kimi opencode hermes aider cursor-agent copilot droid qwen grok pi amp"
    ps -axo tty=,stat=,args= 2>/dev/null | awk -v names="$names" '
    function base(p) { sub(/.*\//, "", p); return p }
    BEGIN { n = split(names, list, " "); for (i = 1; i <= n; i++) known[list[i]] = 1 }
    $2 ~ /\+/ {
        name = base($3);
        if (name ~ /^(node|bun|deno|python[0-9.]*)$/) name = base($4);
        if (name in known) print $1 "\t" name;
    }'
}

list_panes() {
    local current_session="$1"
    local rows filtered rank sorted
    rows="$(tmux list-panes -a -F '#{@agent_status}	#{@agent_status_updated_at}	#{session_name}:#{window_index}.#{pane_index}	#{window_name}	#{?#{@agent_status_label},#{@agent_status_label},#{pane_current_command}}	#{@agent_status_seen}	#{@agent_status_message}	#{pane_tty}')"

    # Panes with a status, plus agents that never reported (no adapter, not
    # restarted since the hooks went in): named by process, state unknown.
    filtered="$(printf '%s\n' "$rows" | awk -F'\t' -v OFS='\t' '
        FILENAME != "-" { agent[$1] = $2; next }
        $1 == "waiting" || $1 == "working" || $1 == "done" { print; next }
        { tty = $8; sub(/^\/dev\//, "", tty); if ($1 == "" && (tty in agent)) { $1 = "running"; $5 = agent[tty]; print } }
    ' <(running_agents) -)"
    [ -z "$filtered" ] && return 0

    # Needs-your-input panes first, then still-working, then finished and
    # not looked at yet, then the rest; most-recently-changed first within each.
    rank='{ order = ($1 == "waiting") ? 0 : ($1 == "working") ? 1 : ($1 == "done" && $6 == "") ? 2 : ($1 == "done") ? 3 : 4; print order "\t" $0 }'
    sorted="$(printf '%s\n' "$filtered" | awk -F'\t' "$rank" | sort -t'	' -k1,1n -k3,3nr | cut -f2-)"

    # Rows in the session we were invoked from get a green "→" marker
    # (ANSI, relies on --ansi in the fzf invocation below) so the
    # session you're currently in stands out from every other one.
    # Several agent panes in one session get a "[i/N]" badge so it's
    # obvious they're siblings and which one is which.
    printf '%s\n' "$sorted" | awk -F'\t' -v cur="$current_session" -v now="$(date +%s)" '
    function age(updated, d) {
        if (updated == "") return "-";
        d = now - updated;
        if (d < 60) return d "s";
        if (d < 3600) return int(d / 60) "m";
        if (d < 86400) return int(d / 3600) "h";
        return int(d / 86400) "d";
    }
    { line[NR] = $0; s = $3; sub(/:.*/, "", s); sess[NR] = s; total[s]++ }
    END {
        # shortcut: awk may count bytes, so non-ASCII session names can still drift; upgrade if those show up.
        for (n = 1; n <= NR; n++) {
            split(line[n], f, "\t");
            s = sess[n];
            badge[n] = (total[s] > 1) ? sprintf("[%d/%d]", ++seen[s], total[s]) : "";
            if (length(f[3]) > target_w) target_w = length(f[3]);
            if (length(badge[n]) > badge_w) badge_w = length(badge[n]);
        }
        fmt = "%s%s%s %s %3s | %-" target_w "s %-" badge_w "s | %s (%s)%s%s\t%s\n";
        for (n = 1; n <= NR; n++) {
            split(line[n], f, "\t");
            dim = "";
            if (f[1] == "waiting")      icon = "⏳ waiting";
            else if (f[1] == "working") icon = "⚙️ working";
            else if (f[1] == "running") { icon = "○ no hooks"; dim = "\033[2m"; }
            else if (f[6] != "")        { icon = "💤 idle   "; dim = "\033[2m"; }
            else                        icon = "✅ done   ";
            num = (n <= 9) ? n : " ";
            s = sess[n];
            marker = (s == cur) ? "\033[1;32m→\033[0m" : " ";
            why = (f[7] != "") ? " · " f[7] : "";
            printf fmt, marker, dim, num, icon, age(f[2]), f[3], badge[n], f[4], f[5], why, (dim != "") ? "\033[0m" : "", f[3];
        }
    }'
}

jump_to() {
    local target="$1" client="${2:-}"
    tmux switch-client ${client:+-c "$client"} -t "${target%%:*}"
    tmux select-window -t "$target"
    tmux select-pane -t "$target"
}

# Longest-waiting pane, then finished panes not looked at yet, cycling onward
# from the current one so repeated presses visit all of them.
jump_next() {
    local client="$1" current_pane="$2" target
    target="$(tmux list-panes -a -F '#{@agent_status}	#{@agent_status_updated_at}	#{session_name}:#{window_index}.#{pane_index}	#{@agent_status_seen}	#{pane_id}' |
        awk -F'\t' -v OFS='\t' '$1 == "waiting" { print 0, $2, $3, $5 } $1 == "done" && $4 == "" { print 1, $2, $3, $5 }' |
        sort -t'	' -k1,1n -k2,2n |
        awk -F'\t' -v cur="$current_pane" '
            NR == 1 { first = $3 }
            found && !pick { pick = $3 }
            $4 == cur { found = 1 }
            END { if (pick == "") pick = first; print pick }')"
    if [ -z "$target" ]; then
        tmux display-message ${client:+-c "$client"} "agent-status: nothing needs you"
        return 0
    fi
    jump_to "$target" "$client"
}

if [ "${1:-}" = "--list" ]; then
    list_panes "${2:-}"
    exit 0
fi

if [ "${1:-}" = "--next" ]; then
    jump_next "${2:-}" "${3:-}"
    exit 0
fi

if [ "${1:-}" = "--dismiss" ]; then
    shift
    # shellcheck source=./agent-status-apply.sh
    source "$CURRENT_DIR/agent-status-apply.sh"
    for target in "$@"; do
        agent_status_apply_to_tmux "$target" "" "" >/dev/null 2>&1 || true
    done
    exit 0
fi

if ! command -v fzf >/dev/null 2>&1; then
    tmux display-message "agent-status: fzf not found (brew install fzf)"
    exit 1
fi

current_pane="${1:-}"
current_session="${current_pane%%:*}"

formatted="$(list_panes "$current_session")"

if [ -z "$formatted" ]; then
    tmux display-message "agent-status: no active panes"
    exit 0
fi

# Display only, never parsed: drops trailing blank lines so "follow" lands on the prompt.
preview="tmux capture-pane -ep -t {2} | awk 'NF { last = NR } { line[NR] = \$0 } END { for (i = 1; i <= last; i++) print line[i] }' | tail -n 300"
preview_size="$(tmux show-option -gqv @agent_status_preview_size 2>/dev/null || true)"

number_binds=""
for n in 1 2 3 4 5 6 7 8 9; do
    number_binds="$number_binds --bind $n:pos($n)+accept"
done

# shellcheck disable=SC2086
choice="$(printf '%s\n' "$formatted" | fzf --multi --delimiter='\t' --with-nth=1 --ansi \
    --prompt="agent panes> " --reverse \
    --preview="$preview" --preview-window="down:${preview_size:-75%}:follow:border-top" \
    --header='enter: jump | 1-9: jump to row | tab: select | ctrl-x: dismiss selected | ctrl-r: refresh' \
    --color='fg:-1,bg:-1,fg+:16:bold,bg+:117,hl:25,hl+:25:bold,info:25,prompt:25,pointer:196,marker:28,header:25,border:-1,label:-1' \
    $number_binds \
    --bind "ctrl-r:reload($CURRENT_DIR/agent-picker.sh --list '$current_session')" \
    --bind "ctrl-x:execute-silent($CURRENT_DIR/agent-picker.sh --dismiss {+2})+reload($CURRENT_DIR/agent-picker.sh --list '$current_session')")" || exit 0 # Esc/ctrl-c (130) or no match (1) is a cancel, not an error

[ -z "$choice" ] && exit 0

target="$(printf '%s' "$choice" | awk -F'\t' '{print $2}')"
jump_to "$target"
