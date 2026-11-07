#!/usr/bin/env bash
# Each preset installs idempotently and uninstalls back to the original file.
set -euo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

roundtrip() { # name config-file file-content install-script
    printf '%s\n' "$3" > "$2"
    cp "$2" "$TMP/original"
    "$4"
    cmp -s "$2" "$TMP/original" && fail "$1: install changed nothing"
    cmp -s "$2.bak.tmux-agent-status" "$TMP/original" || fail "$1: backup is not the original"
    cp "$2" "$TMP/installed"
    "$4"
    cmp -s "$2" "$TMP/installed" || fail "$1: second install changed the file"
    "$4" --uninstall
}

export GEMINI_SETTINGS_FILE="$TMP/gemini.json"
roundtrip gemini "$GEMINI_SETTINGS_FILE" '{"security":{"auth":{"selectedType":"oauth"}}}' "$ROOT/adapters/gemini/install-hooks.sh"
[ "$(jq -c . "$GEMINI_SETTINGS_FILE")" = '{"security":{"auth":{"selectedType":"oauth"}}}' ] || fail "gemini: uninstall left changes"

export CODEX_HOME="$TMP/codex"
mkdir -p "$CODEX_HOME"
roundtrip codex "$CODEX_HOME/hooks.json" '{}' "$ROOT/adapters/codex/install-hooks.sh"
[ "$(jq -c . "$CODEX_HOME/hooks.json")" = '{}' ] || fail "codex: uninstall left changes"

export KIMI_CODE_HOME="$TMP/kimi"
mkdir -p "$KIMI_CODE_HOME"
roundtrip kimi "$KIMI_CODE_HOME/config.toml" 'default_model = "k3"' "$ROOT/adapters/kimi/install-hooks.sh"
cmp -s "$KIMI_CODE_HOME/config.toml" "$TMP/original" || fail "kimi: uninstall did not restore the file"
rm -f "$KIMI_CODE_HOME/config.toml"
"$ROOT/adapters/kimi/install-hooks.sh"
[ ! -e "$KIMI_CODE_HOME/config.toml" ] || fail "kimi: must not create a config"

export XDG_CONFIG_HOME="$TMP/xdg"
mkdir -p "$XDG_CONFIG_HOME/opencode"
roundtrip opencode "$XDG_CONFIG_HOME/opencode/cli.json" '{"animations":true}' "$ROOT/adapters/opencode/install-hooks.sh"
[ "$(jq -c . "$XDG_CONFIG_HOME/opencode/cli.json")" = '{"animations":true}' ] || fail "opencode: uninstall left changes"
[ ! -e "$XDG_CONFIG_HOME/opencode/tmux-agent-status" ] || fail "opencode: uninstall left the plugin"
rm -f "$XDG_CONFIG_HOME/opencode/cli.json"
"$ROOT/adapters/opencode/install-hooks.sh"
[ ! -e "$XDG_CONFIG_HOME/opencode/cli.json" ] || fail "opencode: must not create cli.json"

echo "ok: presets"
