#!/usr/bin/env bash
# Interactive rclone + Google Drive setup for Claude Code backups (Ubuntu).
#
# Usage:
#   bash setup-ubuntu.sh               # full interactive setup (install + OAuth + tests)
#   bash setup-ubuntu.sh --check-only  # no prompts: test an existing config and exit
#
# What it does:
#   1. installs rclone if missing (apt, or user-local ~/.local/bin without sudo)
#   2. asks for + validates the remote name and Drive folder
#   3. runs `rclone authorize drive` (browser sign-in) and captures/validates the token
#   4. writes the remote into rclone's config file
#   5. auto-tests the result: reach Drive, create folder, upload/read/delete round-trip
#   6. updates ~/sessium/config.sh so push.sh/pull.sh use your choices
set -euo pipefail

ok()   { printf '[OK]  %s\n' "$*"; }
warn() { printf '[!]   %s\n' "$*"; }
die()  { printf '[X]   %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- 1. rclone
if ! have rclone; then
  echo "rclone is not installed. Install via:"
  echo "  1) apt  (needs your sudo password)"
  echo "  2) user-local ~/.local/bin  (no sudo, needs curl + unzip)"
  read -r -p "Choose [1/2, default 1]: " choice
  choice="${choice:-1}"
  if [ "$choice" = "2" ]; then
    have curl  || die "curl not found — run: sudo apt install curl unzip"
    have unzip || die "unzip not found — run: sudo apt install curl unzip"
    tmp="$(mktemp -d)"
    echo "Downloading rclone (current linux-amd64)..."
    curl -fsSL -o "$tmp/rclone.zip" https://downloads.rclone.org/rclone-current-linux-amd64.zip
    unzip -q -o "$tmp/rclone.zip" -d "$tmp"
    mkdir -p "$HOME/.local/bin"
    install -m 0755 "$tmp"/rclone-*-linux-amd64/rclone "$HOME/.local/bin/rclone"
    rm -rf "$tmp"
    export PATH="$HOME/.local/bin:$PATH"
    have rclone || die "installed to ~/.local/bin but it is not on PATH — open a new terminal and rerun"
  else
    sudo apt-get install -y rclone || die "apt install failed"
  fi
fi
RCLONE_VER="$(rclone version 2>/dev/null | head -1 | awk '{print $2}')"
ok "rclone $RCLONE_VER found"

CONFIG_FILE="$(rclone config file | tail -1 | tr -d '[:space:]')"
REMOTE_EXISTS() { rclone listremotes 2>/dev/null | sed 's/:$//' | grep -qx "$1"; }

ask() { # ask QUESTION DEFAULT REGEX ERROR-MESSAGE → prints validated answer
  local v
  while :; do
    read -r -p "$1 [$2]: " v
    v="${v:-$2}"
    if [[ "$v" =~ $3 ]]; then printf '%s' "$v"; return 0; fi
    warn "$4 — try again"
  done
}

# ------------------------------------------------------- 2. run_tests helper
run_tests() { # run_tests REMOTE FOLDER — exits nonzero if any mandatory test fails
  local R="$1" F="$2" tmp passed=0 failed=0
  tmp="$(mktemp -d)"
  printf 'claude-drive-setup connectivity test\n' > "$tmp/testfile.txt"

  echo "-- Test 1: reach Google Drive root (lsd $R:)"
  if timeout 30 rclone lsd "$R:" >/dev/null 2>&1; then
    ok "Drive root reachable (token works)"; passed=$((passed+1))
  else warn "could not list Drive root"; failed=$((failed+1)); fi

  echo "-- Test 2: backup folder exists / can be created ($R:$F)"
  if timeout 30 rclone mkdir "$R:$F" >/dev/null 2>&1; then
    ok "folder ready"; passed=$((passed+1))
  else warn "mkdir failed"; failed=$((failed+1)); fi

  echo "-- Test 3: upload → read back → delete round-trip"
  if timeout 60 rclone copy "$tmp/testfile.txt" "$R:$F/_connectivity-test" >/dev/null 2>&1 \
     && timeout 30 rclone cat "$R:$F/_connectivity-test/testfile.txt" 2>/dev/null | grep -q 'connectivity test' \
     && timeout 30 rclone deletefile "$R:$F/_connectivity-test/testfile.txt" >/dev/null 2>&1 \
     && timeout 30 rclone rmdir "$R:$F/_connectivity-test" >/dev/null 2>&1; then
    ok "upload, read back and delete all work"; passed=$((passed+1))
  else warn "round-trip failed"; failed=$((failed+1)); fi

  echo "-- Test 4: account quota visible (about $R:) — non-fatal"
  if timeout 30 rclone about "$R:" 2>/dev/null | grep -q 'Total:'; then
    ok "quota visible"; passed=$((passed+1))
  else warn "about unavailable (harmless with some Drive configs)"; fi

  rm -rf "$tmp"
  if [ "$failed" -gt 0 ]; then die "$failed mandatory test(s) failed — see messages above"; fi
  ok "All tests passed — remote '$R' is ready for use"
}

# --------------------------------------------------- 3. check-only shortcut
DEF_REMOTE="gdrive"; DEF_FOLDER="claude-backup"
DS_CONFIG="$HOME/sessium/config.sh"
if [ -f "$DS_CONFIG" ]; then
  # shellcheck disable=SC1090
  . "$DS_CONFIG"
  DEF_REMOTE="${DRIVE_REMOTE:-gdrive}"; DEF_FOLDER="${DRIVE_DIR:-claude-backup}"
fi
if [ "${1:-}" = "--check-only" ]; then
  REMOTE_EXISTS "$DEF_REMOTE" || die "remote '$DEF_REMOTE' is not configured yet — run this script without --check-only"
  run_tests "$DEF_REMOTE" "$DEF_FOLDER"
  exit 0
fi

# ----------------------------------------------------------- 4. user input
REMOTE="$(ask "Remote name for Google Drive" "$DEF_REMOTE" \
  '^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$' \
  "remote names may contain letters, digits, dashes, underscores (max 32 chars)")"
FOLDER="$(ask "Folder on your Drive for backups" "$DEF_FOLDER" \
  '^[^/\\:*?"<>|]{1,100}$' \
  'folder name cannot contain any of: / \ : * ? " < > |')"

RECONFIGURE=0
if REMOTE_EXISTS "$REMOTE"; then
  read -r -p "Remote '$REMOTE' already exists. Reconfigure (re-authorize) it? [y/N]: " yn
  case "$yn" in
    y|Y) RECONFIGURE=1 ;;
    *)   ok "keeping existing remote — running tests only"; run_tests "$REMOTE" "$FOLDER"
         echo "Next step: $HOME/sessium/push.sh"; exit 0 ;;
  esac
fi

# --------------------------------------------- 5. OAuth via rclone authorize
echo ""
echo "A browser window will open now — sign in to your Google account and click Allow."
echo "When it succeeds, rclone prints a result JSON line in this terminal."
echo ""
TOKEN_JSON=""
if out="$(timeout 300 rclone authorize "drive" 2>&1)"; then
  TOKEN_JSON="$(printf '%s\n' "$out" | grep -E '^\{' | tail -1 || true)"
fi
if [ -z "$TOKEN_JSON" ]; then
  warn "could not capture the result automatically (no browser opened, or you cancelled)."
  echo "If rclone printed a URL above, open it manually, then paste the result JSON here."
  read -r -p "Paste the JSON (starts with {): " TOKEN_JSON
fi
# strip accidental surrounding quotes the user may have copied
TOKEN_JSON="${TOKEN_JSON%\"}"; TOKEN_JSON="${TOKEN_JSON#\"}"
[ -n "$TOKEN_JSON" ] || die "no token provided — setup aborted."
if have python3; then
  python3 - "$TOKEN_JSON" <<'PYEOF' || die "that does not look like a valid rclone token JSON — setup aborted."
import json, sys
d = json.loads(sys.argv[1])
assert isinstance(d, dict) and d.get("access_token")
PYEOF
else
  case "$TOKEN_JSON" in '{'*'}') ;; *) die "that does not look like a token JSON — setup aborted." ;; esac
fi
ok "token captured and validated"

# ------------------------------------------------------- 6. write the remote
# The old section is deleted only now — after the new token is validated — so
# a failed OAuth can never leave this machine without a working remote.
if [ "$RECONFIGURE" = "1" ]; then
  rclone config delete "$REMOTE"
  ok "removed old remote '$REMOTE'"
fi
mkdir -p "$(dirname "$CONFIG_FILE")"
touch "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
{
  echo ""
  echo "[$REMOTE]"
  echo "type = drive"
  echo "token = $TOKEN_JSON"
} >> "$CONFIG_FILE"
ok "remote '$REMOTE' written to $CONFIG_FILE"

# ------------------------------------------------------------- 7. auto-test
run_tests "$REMOTE" "$FOLDER"

if [ -f "$DS_CONFIG" ]; then
  sed -i "s/^DRIVE_REMOTE=.*/DRIVE_REMOTE=\"$REMOTE\"/; s/^DRIVE_DIR=.*/DRIVE_DIR=\"$FOLDER\"/" "$DS_CONFIG"
  ok "updated $DS_CONFIG (remote=$REMOTE folder=$FOLDER)"
fi
echo ""
echo "Setup complete. Next step: $HOME/sessium/push.sh"
echo "Re-verify anytime with:    bash $0 --check-only"
