#!/usr/bin/env bash
# Make sessions from another machine resumable on THIS machine.
# Claude finds sessions by looking in ~/.claude/projects/<munged-repo-path>/,
# where <munged-repo-path> is the repo's absolute path with every "/" replaced by "-".
# If the repo lives at a different path on this machine, its sessions are invisible
# until you copy them into the matching folder — that's what this script does.
#
# Usage:  restore-session.sh <folder-pulled-from-Drive> <repo-path-on-this-machine>
# Example: restore-session.sh -home-recoding-crosswise ~/crosswise
set -euo pipefail
CLAUDE_DIR="$HOME/.claude"

if [ $# -ne 2 ]; then
  echo "Usage: $0 <folder-pulled-from-Drive> <repo-path-on-this-machine>"
  echo "Example: $0 -home-recoding-crosswise ~/crosswise"
  echo ""
  echo "Folders available in ~/.claude/projects:"
  ls -1 "$CLAUDE_DIR/projects" 2>/dev/null || echo "  (none — run pull.sh first)"
  exit 1
fi
src="$1"; repo="$2"
munged="$(printf '%s' "$repo" | sed 's#/#-#g')"

if [ ! -d "$CLAUDE_DIR/projects/$src" ]; then
  echo "No folder '$src' in ~/.claude/projects — run pull.sh first."
  exit 1
fi

if [ "$src" = "$munged" ]; then
  echo "Already matches this machine's path ($munged). Nothing to do."
  exit 0
fi

mkdir -p "$CLAUDE_DIR/projects/$munged"
cp -a "$CLAUDE_DIR/projects/$src/." "$CLAUDE_DIR/projects/$munged/"
echo "✔ Copied '$src' → '$munged'"
echo "Now resume with:  cd $repo && claude --resume"
