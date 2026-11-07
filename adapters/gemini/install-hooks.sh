#!/usr/bin/env bash
# Merges hooks.map into ~/.gemini/settings.json. Pass --uninstall to remove them.
set -euo pipefail

ADAPTER_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd -P "$ADAPTER_DIR/../.." && pwd -P)"

"$PLUGIN_DIR/core/install-json-hooks.sh" "${GEMINI_SETTINGS_FILE:-$HOME/.gemini/settings.json}" \
    gemini "$ADAPTER_DIR/hooks.map" "$@"
