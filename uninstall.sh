#!/usr/bin/env bash
# Remove the sessium binary. Config, ledger and Drive data are left in place.
set -euo pipefail
rm -f "$HOME/.local/bin/sessium"
echo "removed: $HOME/.local/bin/sessium"
echo "left in place: ~/.config/sessium/  ~/.local/state/sessium/  (delete by hand if you want)"
