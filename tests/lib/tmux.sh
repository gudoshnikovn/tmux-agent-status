# Sourced by tests: a private tmux server with one real attached client, so
# nothing reaches the user's server. `tmux` on PATH points at the private one;
# HOME is throwaway because loading the plugin installs adapter hooks.
TMP="$(mktemp -d)"
# Pickers under test get their sockets in here, which tells them from a real popup.
export TMPDIR="$TMP"
REAL_TMUX="$(command -v tmux)"
SOCKET="agentstatus-test-$$"
cleanup() { "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true; "$REAL_TMUX" -L "$SOCKET-outer" kill-server 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/bin" "$TMP/home"
printf '#!/bin/sh\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$TMP/bin/tmux"
chmod +x "$TMP/bin/tmux"
export PATH="$TMP/bin:$PATH" HOME="$TMP/home"
unset TMUX TMUX_PANE
nap() { perl -e "select(undef, undef, undef, $1)"; }
tmux -f /dev/null new-session -d -s main -x 150 -y 40
# The attached client lives in a pane of a second private server, which gives it a real tty.
"$REAL_TMUX" -L "$SOCKET-outer" -f /dev/null new-session -d -x 150 -y 40 "env -u TMUX '$REAL_TMUX' -L '$SOCKET' attach -t main"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(tmux list-clients 2>/dev/null)" ] && break; nap 0.2; done
