#!/bin/zsh

set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
exec /usr/bin/python3 "$ROOT_DIR/tools/run_release_gate.py" "$@"
