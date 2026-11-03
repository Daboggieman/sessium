#!/usr/bin/env bash
# Push Claude Code sessions + config to Google Drive.
# Safe by design: `rclone copy` never deletes anything on Drive.
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
  if [ -e "$CLAUDE_DIR/$src" ]; then
    echo "→ $src"
    rclone copy "$CLAUDE_DIR/$src" "${DRIVE_REMOTE}:${DRIVE_DIR}/${dest}" --transfers 4
  else
    echo "  skip (not present): $src"
  fi
done
echo "✔ Pushed to ${DRIVE_REMOTE}:${DRIVE_DIR}"
