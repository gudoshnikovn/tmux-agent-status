#!/usr/bin/env bash
# TPM only sources *.tmux files directly at a plugin's root - it does
# not look in subdirectories. The real entry point lives in tmux/ (see
# CLAUDE.md's Files section for why it's grouped there alongside
# core/ and adapters/); this is just a shim so TPM's @plugin flow finds
# something to run.
CURRENT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec "$CURRENT_DIR/tmux/agent-status.tmux"
