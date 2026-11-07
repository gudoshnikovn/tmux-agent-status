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
printf '%s\n' "$out" | grep -q '💤 idle .*seen:1.1' || fail "seen pane not shown as idle"
printf '%s\n' "$out" | grep -q '✅ done .*fresh:1.1' || fail "unseen pane not shown as done"
printf '%s\n' "$out" | grep -q '○ unknown.*nohook:1.1.*(opencode)' || fail "agent without hooks missing"
printf '%s\n' "$out" | grep -q '○ unknown.*wrapped:1.1.*(gemini)' || fail "runtime-wrapped agent missing"
printf '%s\n' "$out" | grep -q 'plain:1.1' && fail "grep opencode is not an agent"
printf '%s\n' "$out" | grep -q 'back:1.1' && fail "background process is not the pane's agent"
printf '%s\n' "$out" | grep -q 'dismissed:1.1' && fail "a dismissed pane came back"

raw="$(PATH="$TMP:$PATH" "$ROOT/core/agent-picker.sh" --list busy "" <(echo session))"
out="$(printf '%s\n' "$raw" | cut -f1 | sed $'s/\033\\[[0-9;]*m//g')"
headings="$(printf '%s\n' "$raw" | awk -F'\t' '$2 ~ /^=/ { s = $2; sub(/^=/, "", s); sub(/:.*/, "", s); printf "%s ", s }')"
[ "$headings" = "ask back busy fresh nohook plain seen wrapped " ] || [ "$headings" = "ask busy fresh nohook seen wrapped " ] || fail "sessions not alphabetical: $headings"
block="$(printf '%s\n' "$out" | sed -n '/ busy /,/ fresh /p')"
printf '%s\n' "$block" | head -1 | grep -q '⚙️1 ✅1' || fail "heading has no rollup"
printf '%s\n' "$block" | sed -n 2p | grep -q '⚙️ working' || fail "waiting/working must lead inside a session"
printf '%s\n' "$block" | sed -n 3p | grep -q '✅ done' || fail "done must follow inside a session"
printf '%s\n' "$raw" | awk -F'\t' '$2 ~ /^=busy/' | grep -q $'\033\\[1;32m' || fail "current session not marked"

echo "ok: picker rows"
