#!/usr/bin/env bash
# Picker row contents and order, with fake tmux and ps.
set -euo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/tmux" <<'FAKE'
#!/bin/sh
case "$1" in
list-panes)
    t="$(printf '\t')"
    cat <<ROWS
done${t}100${t}seen:1.1${t}w${t}claude${t}1${t}${t}/dev/ttys001
done${t}200${t}fresh:1.1${t}w${t}claude${t}${t}${t}/dev/ttys002
waiting${t}300${t}ask:1.1${t}w${t}claude${t}${t}permission: Bash${t}/dev/ttys003
working${t}400${t}busy:1.1${t}w${t}claude${t}${t}${t}/dev/ttys004
${t}${t}nohook:1.1${t}w${t}opencode${t}${t}${t}/dev/ttys005
${t}${t}wrapped:1.1${t}w${t}node${t}${t}${t}/dev/ttys006
${t}${t}plain:1.1${t}w${t}zsh${t}${t}${t}/dev/ttys007
${t}${t}back:1.1${t}w${t}zsh${t}${t}${t}/dev/ttys008
${t}500${t}dismissed:1.1${t}w${t}claude${t}${t}${t}/dev/ttys009${t}claude-code
done${t}600${t}busy:2.1${t}w2${t}claude${t}${t}${t}/dev/ttys010
ROWS
    ;;
esac
FAKE
cat > "$TMP/ps" <<'FAKE'
#!/bin/sh
cat <<PROCS
ttys005  S+   /home/me/.opencode/bin/opencode
ttys006  S+   node /usr/local/bin/gemini --flag
ttys007  S+   grep opencode
ttys008  S    opencode
ttys004  S+   claude
ttys009  S+   claude
PROCS
FAKE
chmod +x "$TMP/tmux" "$TMP/ps"

out="$(PATH="$TMP:$PATH" "$ROOT/core/agent-picker.sh" --list none | cut -f1 | sed $'s/\033\\[[0-9;]*m//g')"
fail() { echo "FAIL: $1"; printf '%s\n' "$out"; exit 1; }

order="$(printf '%s\n' "$out" | sed -E 's/.* \| ([a-z]+):.*/\1/' | tr '\n' ' ')"
case "$order" in
    "ask busy busy fresh seen "*|"ask busy fresh busy seen "*) ;;
    *) fail "wrong order: $order" ;;
esac
printf '%s\n' "$out" | grep -q 'ask:1.1.* · permission: Bash' || fail "message missing"
printf '%s\n' "$out" | grep -q '· idle .*seen:1.1' || fail "seen pane not shown as idle"
printf '%s\n' "$out" | grep -q '✓ done .*fresh:1.1' || fail "unseen pane not shown as done"
printf '%s\n' "$out" | grep -q '? unknown.*nohook:1.1.*(opencode)' || fail "agent without hooks missing"
printf '%s\n' "$out" | grep -q '? unknown.*wrapped:1.1.*(gemini)' || fail "runtime-wrapped agent missing"
printf '%s\n' "$out" | grep -q 'plain:1.1' && fail "grep opencode is not an agent"
printf '%s\n' "$out" | grep -q 'back:1.1' && fail "background process is not the pane's agent"
printf '%s\n' "$out" | grep -q 'dismissed:1.1' && fail "a dismissed pane came back"

echo session > "$TMP/view"
raw="$(PATH="$TMP:$PATH" "$ROOT/core/agent-picker.sh" --list busy "" "$TMP/view" | sed $'s/\033\\[[0-9;]*m//g')"
out="$raw"
headings="$(printf '%s\n' "$raw" | awk -F'\t' '$2 ~ /^=/ { print $1 }' | sed -E 's/^. ([^ ]+).*/\1/' | tr '\n' ' ')"
[ "$headings" = "ask busy fresh nohook seen wrapped " ] || fail "sessions not alphabetical: $headings"
printf '%s\n' "$raw" | grep -q $'^→ busy …1 ✓1\t=busy:' || fail "current session's heading wrong: marker, rollup, no number"
busy="$(printf '%s\n' "$raw" | grep -A2 '^→ busy ')"
printf '%s\n' "$busy" | sed -n 2p | grep -q '… working' || fail "working must lead inside a session"
printf '%s\n' "$busy" | sed -n 3p | grep -q '✓ done' || fail "done must follow inside a session"
numbers="$(printf '%s\n' "$raw" | awk -F'\t' '$2 !~ /^=/' | cut -c1-3 | tr -cd '0-9')"
[ "$numbers" = 1234567 ] || fail "only panes get numbers, in a row: $numbers"

[ "$(tr '\n' ' ' < "$TMP/view.positions")" = "2 4 5 7 9 11 13 " ] || fail "positions must point at panes: $(tr '\n' ' ' < "$TMP/view.positions")"
echo "ok: picker rows"
