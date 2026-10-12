#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
cd "$PROJECT_DIR"
swift build -c release --product message-helper-host
codesign --force --sign - "$PROJECT_DIR/.build/release/message-helper-host"
