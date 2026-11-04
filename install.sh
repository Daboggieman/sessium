#!/usr/bin/env bash
# Install sessium (Linux): copy the CLI to ~/.local/bin and sanity-check deps.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin"

mkdir -p "$BIN"
install -m 0755 "$DIR/linux/sessium" "$BIN/sessium"
echo "installed: $BIN/sessium"

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required"; exit 1; }
command -v rclone >/dev/null 2>&1 \
  || echo "NOTE: rclone not found — run:  bash $DIR/setup-ubuntu.sh"

if ! [[ ":$PATH:" == *":$BIN:"* ]]; then
  echo "NOTE: $BIN is not on your PATH. Add to your shell profile:"
  echo "      export PATH=\"\$HOME/.local/bin:\$PATH\""
fi
echo "next: sessium status   (or bash $DIR/setup-ubuntu.sh for first-time Drive setup)"
