#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT_DIR/tools/generate_klms_ios_xcode_project.py" >/dev/null
open "$ROOT_DIR/apps/KLMSync/Xcode/KLMSiOS/KLMSiOS.xcodeproj"
