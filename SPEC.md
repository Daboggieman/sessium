# sessium — SPEC (cross-platform contract)

Both native versions — `linux/sessium` (Python 3) and `windows/sessium.ps1`
(PowerShell 5.1+) — read and write the same Drive data and the same ledger
format. This file is the contract. If the two versions disagree, this file
wins and one of them gets fixed.

## 1. Drive layout (never changes lightly; data already lives here)

```
<remote>:<folder>/
  projects/<munged-path>/<session-id>.jsonl     ← conversations
  projects/<munged-path>/<session-id>/...       ← session data folders
  projects/<munged-path>/memory/...             ← persistent memory
  config/settings.json, config/skills/, config/file-history/
  config/installed_plugins.json                 ← plugin registry only
```

Default `<remote>` is `gdrive`, default `<folder>` is `claude-backup`;
both come from `~/.config/sessium/config.json` (or the platform fallbacks —
see §5). sessium never deletes from the remote.

## 2. Munging rule

Claude Code stores a project's sessions under the project's absolute path
with every `/` replaced by `-`, leading slash included:

    /home/recoding/Kairo-v1  →  -home-recoding-Kairo-v1

Windows paths munge the same way: every `\` becomes `-` (e.g.
`C:\Users\me\repo` → `C:-Users-me-repo`). A session id is the transcript
file's stem (UUID). The ledger key is `<munged>/<session-id>`.

## 3. Ledger (per machine — never synced)

Path: `~/.local/state/sessium/state.json` (Linux) /
`%LOCALAPPDATA%\sessium\state.json` (Windows). Schema v1:

```json
{
  "version": 1,
  "sessions": {
    "<munged>/<session-id>": {
      "project": "<munged>",
      "id": "<session-id>",
      "local_md5": "<md5 of the local copy at last sync>",
      "remote_md5": "<md5 of the Drive copy at last sync>",
      "last_synced": "2026-11-04T06:07:08Z"
    }
  }
}
```

`last_synced` is UTC, `%Y-%m-%dT%H:%M:%SZ`. Timestamps are informational —
classification uses md5s only. An unreadable ledger is a loud warning plus a
fresh start; the bootstrap rule (§4) re-records matching sessions, so losing
it must never cause data loss or mass conflicts.

## 4. Classification (one row per session present on either side)

For each session, compare current md5s against the ledger record:

| local copy | remote copy | ledger | state |
|---|---|---|---|
| unchanged   | unchanged   | present    | `in-sync` |
| changed     | unchanged   | present    | `push` |
| unchanged   | changed     | present    | `pull` |
| changed     | changed     | present    | `conflict` |
| present     | present     | **absent** | md5s equal → `in-sync` (bootstrap: record silently); else `conflict` |
| present     | missing     | absent     | `new-here` |
| missing     | present     | absent     | `new-there` |
| present     | missing     | present    | `new-here` (re-upload — sessium never deletes) |
| missing     | present     | present    | `new-there` (re-download) |

"changed" = md5 differs from the ledger's stored value. A side whose md5
cannot be read is treated as changed (never silently overwrite).

## 5. Configuration

Precedence, first match wins: env `SESSIUM_CONFIG` (Linux) / `SESSIUM_RCLONE_CONFIG`… see each version's env table below, then `<config dir>/sessium/config.json`, then legacy `~/sessium/config.sh` (`DRIVE_REMOTE`, `DRIVE_DIR`), then defaults `gdrive` / `claude-backup`.

config.json:

```json
{ "rclone_remote": "gdrive", "drive_folder": "claude-backup" }
```

Env overrides (both versions honor the same names where the OS allows):

| env var | meaning | default |
|---|---|---|
| `SESSIUM_CLAUDE_DIR` | Claude data root | `~/.claude` |
| `SESSIUM_CONFIG` | config file path | `<xdg config>/sessium/config.json` |
| `SESSIUM_STATE` | ledger path | `<xdg state>/sessium/state.json` |
| `SESSIUM_RCLONE_BIN` | rclone binary | `rclone` on PATH |

## 6. Conflict semantics (decided 2026-11-03, PLAN §3)

Transcripts are never line-merged.

- `sync` resolves a conflict automatically by **newest-wins** (Drive ModTime
  vs local mtime, both UTC; tie goes to local) when no terminal is attached
  (cron, pipes). On a terminal it prompts `[L]ocal / [R]emote / [B]oth
  (newest wins) / [S]kip`; empty answer = newest-wins.
- `push` / `pull` never touch conflicts — they skip and say so.
- **The loser is never deleted.** A losing local copy is moved to
  `<claude-dir>/projects/<munged>/revert/<id>.revert-<YYYYmmdd-HHMMSS>.jsonl`;
  a losing remote copy is downloaded there first, then overwritten.
  Sub-second collisions of the timestamp get a `-N` suffix before `.jsonl`.
- The `revert/` folder is machine-local, never synced, and is what a future
  `sessium revert <id>` will list.

## 7. Command surface (parity target)

`list`, `status`, `check`, `setup` (phase 1) · `push`, `pull`, `sync`
(phase 2) · `diff`, `resolve`, `revert`, `adopt` (phase 3). All take
`--project <munged>`; `sync` additionally `--interactive`. Exit codes: `0`
success (skips are not failures), `1` real failures, `130` interrupted.

## 8. Transport rules

All Drive I/O goes through rclone; the only commands used are
`version`, `lsd`, `lsf`, `lsjson --recursive --hash`, `copyto`, `mkdir`,
`deletefile`, `rmdir`, `about`, `authorize`, `config file`. Uploads and
downloads are `copyto` of exact paths (rclone creates missing parent
folders). After a successful transfer, both ledger md5s are set to the
transferred copy's md5.
