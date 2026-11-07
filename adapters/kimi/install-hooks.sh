#!/usr/bin/env bash
# Writes hooks.map as a managed block in Kimi Code's config.toml, replacing any
# previous block so reloads stay idempotent. Pass --uninstall to remove it.
set -euo pipefail

ADAPTER_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd -P "$ADAPTER_DIR/../.." && pwd -P)"
CONFIG="${KIMI_CODE_HOME:-$HOME/.kimi-code}/config.toml"
BEGIN="# >>> tmux-agent-status"
END="# <<< tmux-agent-status"

[ -f "$CONFIG" ] || exit 0

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

awk -v begin="$BEGIN" -v end="$END" '
    $0 == begin { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip' "$CONFIG" > "$tmp"

if [ "${1:-}" != "--uninstall" ]; then
    {
        printf '%s\n' "$BEGIN"
        # TOML literal strings: matchers and paths need no escaping.
        awk -v cmd="$PLUGIN_DIR/core/agent-status.sh" 'NF >= 3 && $1 !~ /^#/ {
            print "[[hooks]]";
            print "event = \"" $1 "\"";
            if ($2 != "-") print "matcher = \047" $2 "\047";
            print "command = \047" cmd " " $3 " --tool kimi\047";
            print "timeout = 10\n";
        }' "$ADAPTER_DIR/hooks.map"
        printf '%s\n' "$END"
    } >> "$tmp"
fi

if ! cmp -s "$tmp" "$CONFIG"; then
    cp -n "$CONFIG" "$CONFIG.bak.tmux-agent-status" 2>/dev/null || true
    cat "$tmp" > "$CONFIG"
fi
