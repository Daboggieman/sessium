#!/usr/bin/env bash
# Remove the sessium binary and its helpers. Config, ledger and Drive data
# are left in place.
set -euo pipefail
rm -f "$HOME/.local/bin/sessium" "$HOME/.local/bin/setup-ubuntu.sh"
echo "removed: $HOME/.local/bin/sessium (and setup-ubuntu.sh)"
rm -f "$HOME/.local/share/man/man1/sessium.1" \
      "$HOME/.local/share/bash-completion/completions/sessium" 2>/dev/null || true
echo "left in place: ~/.config/sessium/  ~/.local/state/sessium/  (delete by hand if you want)"
