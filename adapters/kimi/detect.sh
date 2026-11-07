#!/usr/bin/env bash
# Exit 0 if kimi appears usable on this machine.
set -euo pipefail

command -v kimi >/dev/null 2>&1 && exit 0
exit 1
