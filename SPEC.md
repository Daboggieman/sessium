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
(phase 2) · `diff`, `resolve`, `revert`, `adopt` (phase 3) · `version`,
`log` (no id: alias for `list`; with an id: history snapshots), `open`
(Batch 3). All tree-walking commands take `--project <munged>`. `--json`
(SPEC §9) on `list`, `status`, `diff`; `--dry-run` on `push`, `pull`,
`sync`, `revert`, `adopt`, `open`; `sync` additionally `--interactive`.
Exit codes: `0` success (skips are not failures), `1` real failures,
`130` interrupted.

`push`/`pull`/`sync` hold a per-machine lock file (`sync.lock` beside the
ledger) so a scheduled run and a manual run can't transfer concurrently;
`--dry-run` never locks. A lock older than 10 minutes is broken with a
warning (crashed run); a fresh one is a hard error.

## 8. Transport rules

All Drive I/O goes through rclone; the only commands used are
`version`, `lsd`, `lsf`, `lsjson --recursive --hash`, `copyto`, `mkdir`,
`deletefile`, `rmdir`, `about`, `authorize`, `config file`. Uploads and
downloads are `copyto` of exact paths (rclone creates missing parent
folders). After a successful transfer, both ledger md5s are set to the
transferred copy's md5.

## 9. `--json` output schema

`--json` (on `list`, `status`, `diff`, and `search` once Batch 4 lands)
prints ONE JSON document on stdout — indent 2, keys sorted — and nothing
else. Human chatter stays on stderr. All mtimes are UTC
`%Y-%m-%dT%H:%M:%SZ` strings or `null`, so both versions serialize
identically. Consumers must ignore unknown keys (the schema is additive).

- **`list --json [--titles]`** — array, newest first:
  `[{ "project", "id", "path", "size", "mtime", ("title") }]`.
  `title` is present only with `--titles`.

- **`status --json`** — object:
  `{ "remote", "reachable", "projects", "sessions",
     "counts": { "<state>": n },
     "rows": [ { "project", "id", "state",
                 "local":  { "size", "md5", "mtime" } | null,
                 "remote": { "size", "md5", "mtime" } | null,
                 "last_synced": "<utc>" | null } ] }`
  `reachable: false` means rows were classified against a local-only view
  (Drive unreachable).

- **`diff <id> --json`** — object:
  `{ "project", "id", "state",
     "local":  { "path", "size", "md5", "mtime", "messages", "last" } | null,
     "remote": { "size", "md5", "mtime", "messages", "last" } | null,
     "ledger": { "last_synced", "local_md5", "remote_md5" } | null }`

- **`search <q> --json`** (Batch 4) — array of
  `{ "project", "id", "title", "snippet", "where": "title" | "body",
     "mtime" }`, best match first.

## 10. History snapshots (Batch 4)

When a transfer overwrites a copy that had unsynced changes, the replaced
bytes are ALSO kept content-addressed under the session's data folder:
`projects/<munged>/<sid>/history/<seq>-<md5-8>.jsonl` (`seq` zero-padded
4 digits, in order taken). Identical content ⇒ identical name ⇒ free dedup.
History writes never touch the ledger. `sessium log <id>` lists them;
`sessium checkout <id> <seq>` swaps one back (the displaced copy is itself
snapshotted first). `revert/` and `history/` are machine-local, never
synced, and excluded from adopt.
