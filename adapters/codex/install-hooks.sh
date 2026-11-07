#!/usr/bin/env bash
# Merges hooks.map into ~/.codex/hooks.json. Pass --uninstall to remove them.
# Codex runs them only after you trust them once with /hooks.
set -euo pipefail

ADAPTER_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd -P "$ADAPTER_DIR/../.." && pwd -P)"

"$PLUGIN_DIR/core/install-json-hooks.sh" "${CODEX_HOME:-$HOME/.codex}/hooks.json" \
    codex "$ADAPTER_DIR/hooks.map" "$@"
