# Shared settings for the sessium sync scripts. Sourced by push.sh and pull.sh.
# Edit these two lines if you used a different name/folder in `rclone config`:
DRIVE_REMOTE="gdrive"
DRIVE_DIR="claude-backup"

CLAUDE_DIR="$HOME/.claude"

# What gets synced. Format: "local-path-inside-.claude|path-on-Drive-relative-to-$DRIVE_DIR"
# A directory is copied as a directory; a single file names its exact Drive path.
SYNC_ITEMS=(
  "projects|projects"                                # all sessions + memory (the conversations)
  "settings.json|config/settings.json"               # your Claude Code settings
  "skills|config/skills"                             # your skills
  "file-history|config/file-history"                 # session rewind history
  "plugins/installed_plugins.json|config/installed_plugins.json"  # plugin registry
  "drive-sync|drive-sync"                            # legacy copies of these scripts (pre-sessium machines)
  "../sessium|sessium"                                 # this project itself (bootstrap new machines)
)
