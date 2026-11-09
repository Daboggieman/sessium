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
{ "rclone_remote": "gdrive", "drive_folder": "claude-backup",
  "seeker_url": "", "seeker_token": "" }
```

`seeker_url` / `seeker_token` are optional (search integration with the
[seeker](https://github.com/Daboggieman/seeker) engine — Tailscale-only,
bearer-auth). With `sessium setup --encrypted`, `rclone_remote` becomes the
crypt remote `sessium-crypt` and `drive_folder` becomes `""` (the crypt root
IS the old plain root); the Drive layout is unchanged underneath, just
ciphertext.

A key present in config.json is honored **even when its value is an empty
string** — only an absent key (or JSON `null`) falls back to the default.
This matters after `setup --encrypted`: a truthy check on `drive_folder: ""`
silently reverted to the default `claude-backup`, and every push forked into
`<crypt>:claude-backup/` instead of landing at the crypt root.

Env overrides (both versions honor the same names where the OS allows):

| env var | meaning | default |
|---|---|---|
| `SESSIUM_CLAUDE_DIR` | Claude data root | `~/.claude` |
| `SESSIUM_CONFIG` | config file path | `<xdg config>/sessium/config.json` |
| `SESSIUM_STATE` | ledger path | `<xdg state>/sessium/state.json` |
| `SESSIUM_RCLONE_BIN` | rclone binary | `rclone` on PATH |
| `SESSIUM_SYSTEMD_DIR` | user unit dir (`schedule`) | `~/.config/systemd/user` |
| `SESSIUM_COPY_TIMEOUT` | fixed transfer timeout, seconds | size-scaled, see §8 |
| `SESSIUM_RETRY_DELAY_SCALE` | multiplier on retry backoff (test knob) | `1.0` |

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
(phase 3.5) · `search`, `seek`, `checkout`, `gc` (Batch 4) · `schedule`,
`hook`, `setup --encrypted` (Batch 5) · `export`, `onboard` (Batch 6).
All tree-walking commands take `--project <munged>`. `--json`
(SPEC §9) on `list`, `status`, `diff`, `search`; `--dry-run` on `push`,
`pull`, `sync`, `revert`, `adopt`, `open`, `checkout`, `gc`; `sync`
additionally `--interactive` and `--only memory|skills` (ledger-less
two-way fast lane, per-file newest-wins, never deletes). `--quiet` on
`push`/`pull`/`sync` silences chatter (hooks/cron); errors still print.
`--debug` (alias `--verbose`) prints every rclone call and is accepted
on either side of the subcommand. Exit codes: `0` success (skips are
not failures), `1` real failures, `130` interrupted.

Every push/pull/sync ends with one summary line in this shape (both
versions byte-identical; zero counts still shown):

```
pushed: N   pulled: N   in-sync: N [FAILED: N] [resolved: N] [skipped: N]
```

`push`/`pull`/`sync` hold a per-machine lock file (`sync.lock` beside the
ledger) so a scheduled run and a manual run can't transfer concurrently;
`--dry-run` never locks. A lock older than 10 minutes is broken with a
warning (crashed run); a fresh one is a hard error.

`check --full` extends the six-step self-test with a read-only ledger audit:
dead ledger entries (recorded, gone from both sides — informational), Drive
orphans (never synced from this machine — informational), and an md5
spot-check on a deterministic sample of up to 10 in-sync sessions (live
local bytes vs the live Drive hash); a spot-check mismatch exits `1`.

Automation: `sessium schedule [--interval MIN] [--off] [--print]` manages a
systemd **user** timer running `sessium sync`; `sessium hook [--off] [--print]`
manages a Claude Code **Stop hook** running `sessium push --quiet` (only
sessium's entries in settings.json are ever touched). `setup --encrypted`
wraps the plain remote in an rclone crypt remote `sessium-crypt`, re-points
config.json and prints the generated password exactly once.

## 8. Transport rules

All Drive I/O goes through rclone; the only commands used are
`version`, `lsd`, `lsf`, `lsjson --recursive --hash`, `copyto`, `copy`,
`mkdir`, `deletefile`, `rmdir`, `about`, `authorize`, `config file`,
`config create` (setup --encrypted). Uploads and downloads are `copyto` of
exact paths (rclone creates missing parent folders). After a successful
transfer, both ledger md5s are set to the transferred copy's md5.

**Timeouts and retries** (both versions; metadata calls like `lsjson`/`lsd`
keep the short fixed timeout and never retry):

- A file transfer's timeout scales with the file size:
  `max(300 s, 10 s/MB)` — ~100 KB/s sustained rate, floor 300 s.
  `SESSIUM_COPY_TIMEOUT=<seconds>` overrides with a fixed value.
- A timeout, or rclone exit code 5 (transient), 6 (retries exhausted) or
  8 (transfers exhausted), is retried **2 times** with backoff 2 s then 4 s
  (`SESSIUM_RETRY_DELAY_SCALE` multiplies the delays; tests use 0).
  `copyto`/`copy` overwrite whole files, so a blind re-attempt is safe.
- Everything else (rc 2/3/4 not-found, 7 fatal) fails immediately —
  retrying a permanent error just burns time.

**Remote URLs** tolerate a leading slash after the colon: with a crypt
config (`drive_folder: ""`), sessium emits `<remote>:/projects/…` and both
real rclone and the test fake treat that as the remote root.

## 9. `--json` output schema

`--json` (on `list`, `status`, `diff`, and `search`)
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
  With `--messages` also on, an additive `"preview"` key appears when both
  copies are present: `{ "common", "local_added": [[role, text]…],
  "remote_added": [[role, text]…] }` (the divergence past the common prefix).

- **`search <q> --json`** — array of
  `{ "project", "id", "title", "snippet", "where": "title" | "body" |
     "semantic", "mtime" }`, best match first (`mtime` is `null` on
  semantic hits; `title` may be `""`).

## 10. History snapshots (Batch 4)

When a transfer overwrites a copy that had unsynced changes, the replaced
bytes are ALSO kept content-addressed under the session's data folder:
`projects/<munged>/<sid>/history/<seq>-<md5-8>.jsonl` (`seq` zero-padded
4 digits, in order taken). Identical content ⇒ identical name ⇒ free dedup.
History writes never touch the ledger. `sessium log <id>` lists them;
`sessium checkout <id> <seq>` swaps one back (the displaced copy is itself
snapshotted first). `revert/` and `history/` are machine-local, never
synced, and excluded from adopt.
