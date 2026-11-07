#!/usr/bin/env bash
# Merges one adapter's hooks.map into a tool's JSON hook config (the
# {"hooks": {"<Event>": [{"matcher": ..., "hooks": [...]}]}} shape shared by
# Claude Code, Codex and Gemini CLI). Additive and idempotent: runs on every
# tmux reload, and only ever touches entries pointing inside this plugin.
#
# Usage: install-json-hooks.sh <config-file> <tool> <hooks.map> [--hook <cmd>] [--label <text>] [--uninstall]
#
# hooks.map lines: <event> <matcher, or - for none> <working|waiting|done|clear>

set -euo pipefail

PLUGIN_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

config_file="$1"
tool="$2"
map_file="$3"
shift 3

hook_cmd="$PLUGIN_DIR/core/agent-status.sh"
label=""
uninstall=""
while [ $# -gt 0 ]; do
    case "$1" in
        --hook) hook_cmd="$2"; shift 2 ;;
        --label) label="$2"; shift 2 ;;
        --uninstall) uninstall=1; shift ;;
        *) echo "install-json-hooks.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done

if ! command -v jq >/dev/null 2>&1; then
    echo "tmux-agent-status: jq not found, skipping $tool hook install." >&2
    echo "Install jq and re-source your tmux config, or add hooks manually that call:" >&2
    echo "$hook_cmd <working|waiting|done|clear> --tool $tool" >&2
    exit 0
fi

if [ ! -f "$config_file" ]; then
    [ -n "$uninstall" ] && exit 0
    mkdir -p "$(dirname "$config_file")"
    echo '{}' > "$config_file"
fi

entries='[]'
if [ -z "$uninstall" ]; then
    suffix="--tool $tool"
    [ -n "$label" ] && suffix="$suffix --label $label"
    entries="$(awk 'NF >= 3 && $1 !~ /^#/ { print $1 "\t" $2 "\t" $3 }' "$map_file" |
        jq -Rn --arg cmd "$(printf '%q' "$hook_cmd")" --arg suffix "$suffix" '
            [inputs | split("\t") | {
                event: .[0],
                matcher: (if .[1] == "-" then "" else .[1] end),
                command: "\($cmd) \(.[2]) \($suffix)"
            }]')"
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# Strip every entry of ours for every event first, so changing a matcher or
# dropping an event migrates old installs instead of leaving stale duplicates.
jq --arg root "$(printf '%q' "$PLUGIN_DIR/")" --argjson entries "$entries" '
    def ours: ((.command? // "") | startswith($root));
    (.hooks // {}) as $old
    | .hooks = ($old | with_entries(
        if (.value | type) == "array" then
            .value |= (map(if (.hooks | type) == "array" then .hooks |= map(select(ours | not)) else . end)
                | map(select((.hooks | type) != "array" or (.hooks | length) > 0)))
        else . end)
        | with_entries(select(.value != [])))
    | reduce $entries[] as $e (.; .hooks[$e.event] += [{
        matcher: $e.matcher,
        hooks: [{type: "command", command: $e.command}]
    }])
    | if .hooks == {} then del(.hooks) else . end
' "$config_file" > "$tmp"

if ! cmp -s "$tmp" "$config_file"; then
    cp -n "$config_file" "$config_file.bak.tmux-agent-status" 2>/dev/null || true
    cat "$tmp" > "$config_file"
fi
