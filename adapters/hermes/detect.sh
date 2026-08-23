#!/usr/bin/env bash
# Exit 0 if the Hermes Agent CLI appears usable on this machine.
set -euo pipefail

command -v hermes >/dev/null 2>&1 && exit 0
exit 1
