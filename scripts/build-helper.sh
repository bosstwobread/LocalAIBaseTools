#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
cd "$PROJECT_DIR"
swift build --package-path MacHelper -c release --product mac-helper-host
BIN_DIR="$(swift build --package-path MacHelper -c release --show-bin-path)"
mkdir -p "$PROJECT_DIR/dist"
cp "$BIN_DIR/mac-helper-host" "$PROJECT_DIR/dist/mac-helper-host"
codesign --force --sign - "$PROJECT_DIR/dist/mac-helper-host"
