#!/usr/bin/env bash
# RETIRED — use `sessium pull` / `sessium sync` instead (kept for reference).
# Pull Claude Code sessions + config back from Google Drive (e.g. onto a new machine).
# Safe by design: `rclone copy` never deletes anything on this machine.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/config.sh"

command -v rclone >/dev/null 2>&1 || {
  echo "rclone is not installed. One-time setup:  sudo apt install rclone   (then see README.md)"
  exit 1
}
rclone listremotes 2>/dev/null | grep -qx "${DRIVE_REMOTE}:" || {
  echo "Remote '${DRIVE_REMOTE}' is not configured yet. One-time setup:  rclone config   (see README.md)"
  exit 1
}

for item in "${SYNC_ITEMS[@]}"; do
  src="${item%%|*}"; dest="${item##*|}"
  echo "← $src"
  rclone copy "${DRIVE_REMOTE}:${DRIVE_DIR}/${dest}" "$CLAUDE_DIR/$src" --transfers 4
done
echo "✔ Pulled into $CLAUDE_DIR"
echo "If the project paths differ on this machine, run: $DIR/restore-session.sh  (see README.md)"
