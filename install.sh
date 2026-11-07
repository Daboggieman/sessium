#!/usr/bin/env bash
# Install sessium (Linux): copy the CLI to ~/.local/bin, the man page and
# bash completion into ~/.local, and sanity-check deps.
#
# Runs two ways:
#   bash install.sh          — from a repo checkout, installs the local files
#   curl -fsSL https://raw.githubusercontent.com/Daboggieman/sessium/master/install.sh | bash
#                            — no checkout: fetches the files from GitHub
set -euo pipefail
# BASH_SOURCE is unset when the script is piped into bash (curl | bash) and
# set -u would abort on it — fall back to $0 ("bash" when piped).
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
BIN="$HOME/.local/bin"

# From a checkout, install the files in place. Piped in, there is no checkout
# ($DIR is just the caller's cwd), so pull the same files from master first.
RAW="https://raw.githubusercontent.com/Daboggieman/sessium/master"
if [ -f "$DIR/linux/sessium" ] && [ -f "$DIR/setup-ubuntu.sh" ]; then
  CLI="$DIR/linux/sessium"; SETUP="$DIR/setup-ubuntu.sh"
  MAN="$DIR/docs/sessium.1"; COMP="$DIR/completions/sessium.bash"
else
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  echo "no checkout found — fetching files from $RAW"
  fetch() { curl -fsSL "$RAW/$1" -o "$TMP/$2"; }
  fetch "linux/sessium" "sessium"
  fetch "setup-ubuntu.sh" "setup-ubuntu.sh"
  fetch "docs/sessium.1" "sessium.1" || true                # best-effort extras
  fetch "completions/sessium.bash" "sessium.bash" || true
  CLI="$TMP/sessium"; SETUP="$TMP/setup-ubuntu.sh"
  MAN="$TMP/sessium.1"; COMP="$TMP/sessium.bash"
fi

mkdir -p "$BIN"
install -m 0755 "$CLI" "$BIN/sessium"
install -m 0755 "$SETUP" "$BIN/setup-ubuntu.sh"
echo "installed: $BIN/sessium (plus setup-ubuntu.sh for 'sessium setup')"

# man page (best-effort)
if mkdir -p "$HOME/.local/share/man/man1" 2>/dev/null \
   && install -m 0644 "$MAN" "$HOME/.local/share/man/man1/sessium.1" 2>/dev/null; then
  echo "installed: ~/.local/share/man/man1/sessium.1"
else
  echo "NOTE: man page not installed (see docs/sessium.1)"
fi

# bash completion (best-effort); zsh/fish users: see `make completions`
if mkdir -p "$HOME/.local/share/bash-completion/completions" 2>/dev/null \
   && install -m 0644 "$COMP" \
      "$HOME/.local/share/bash-completion/completions/sessium" 2>/dev/null; then
  echo "installed: bash completion"
else
  echo "NOTE: bash completion not installed (see completions/)"
fi

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required"; exit 1; }
command -v rclone >/dev/null 2>&1 \
  || echo "NOTE: rclone not found — run:  sessium setup"

if ! [[ ":$PATH:" == *":$BIN:"* ]]; then
  echo "NOTE: $BIN is not on your PATH. Add to your shell profile:"
  echo "      export PATH=\"\$HOME/.local/bin:\$PATH\""
fi
echo "next: sessium status   (or sessium setup for first-time Drive setup)"
