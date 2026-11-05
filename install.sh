#!/usr/bin/env bash
# Install sessium (Linux): copy the CLI to ~/.local/bin, the man page and
# bash completion into ~/.local, and sanity-check deps.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin"

mkdir -p "$BIN"
install -m 0755 "$DIR/linux/sessium" "$BIN/sessium"
echo "installed: $BIN/sessium"

# man page (best-effort)
if mkdir -p "$HOME/.local/share/man/man1" 2>/dev/null \
   && install -m 0644 "$DIR/docs/sessium.1" "$HOME/.local/share/man/man1/sessium.1" 2>/dev/null; then
  echo "installed: ~/.local/share/man/man1/sessium.1"
else
  echo "NOTE: man page not installed (see docs/sessium.1)"
fi

# bash completion (best-effort); zsh/fish users: see `make completions`
if mkdir -p "$HOME/.local/share/bash-completion/completions" 2>/dev/null \
   && install -m 0644 "$DIR/completions/sessium.bash" \
      "$HOME/.local/share/bash-completion/completions/sessium" 2>/dev/null; then
  echo "installed: bash completion"
else
  echo "NOTE: bash completion not installed (see completions/)"
fi

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required"; exit 1; }
command -v rclone >/dev/null 2>&1 \
  || echo "NOTE: rclone not found — run:  bash $DIR/setup-ubuntu.sh"

if ! [[ ":$PATH:" == *":$BIN:"* ]]; then
  echo "NOTE: $BIN is not on your PATH. Add to your shell profile:"
  echo "      export PATH=\"\$HOME/.local/bin:\$PATH\""
fi
echo "next: sessium status   (or bash $DIR/setup-ubuntu.sh for first-time Drive setup)"
