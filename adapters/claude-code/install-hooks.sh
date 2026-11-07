#!/usr/bin/env bash
# Merges hooks.map into ~/.claude/settings.json and every profile's settings.
# Pass --uninstall to remove them again.

set -euo pipefail

ADAPTER_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd -P "$ADAPTER_DIR/../.." && pwd -P)"

# Profiles launched with CLAUDE_CONFIG_DIR=~/.claude-<name> read only
# their own settings.json, so ~/.claude's hooks never fire there.
if [ -n "${CLAUDE_SETTINGS_FILE:-}" ]; then
    files=("$CLAUDE_SETTINGS_FILE")
else
    files=("$HOME/.claude/settings.json")
    for f in "$HOME"/.claude-*/settings.json; do
        [ -f "$f" ] && files+=("$f")
    done
fi

for f in "${files[@]}"; do
    # Shown in the picker: ~/.claude -> "claude", ~/.claude-personal -> "claude-personal".
    profile="$(basename "$(dirname "$f")")"
    "$PLUGIN_DIR/core/install-json-hooks.sh" "$f" claude-code "$ADAPTER_DIR/hooks.map" \
        --hook "$ADAPTER_DIR/hook.sh" --label "${profile#.}" "$@"
done
