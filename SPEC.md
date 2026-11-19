# sessium — SPEC (cross-platform contract)

Both native versions — `linux/sessium` (Python 3) and `windows/sessium.ps1`
(PowerShell 5.1+) — read and write the same Drive data and the same ledger
format. This file is the contract. If the two versions disagree, this file
wins and one of them gets fixed.

## 1. Drive layout (never changes lightly; data already lives here)

```
<remote>:<folder>/
  projects/<munged-path>/<sid>-<rawmd5>.jsonl.gz  ← conversations (gzip; raw md5 in the name)
  projects/<munged-path>/<sid>.jsonl              ← legacy objects, still readable forever
  projects/<munged-path>/<sid>/...                ← session data folders
  projects/<munged-path>/memory/...               ← persistent memory
  codex/projects/<munged-path>/<sid>-<rawmd5>.jsonl.gz ← Codex CLI rollouts
  codex/projects/<munged-path>/<sid>.jsonl             ← legacy rollouts, readable forever
  config/settings.json, config/skills/, config/file-history/
  config/installed_plugins.json                 ← plugin registry only
```

Default `<remote>` is `gdrive`, default `<folder>` is `claude-backup`;
both come from `~/.config/sessium/config.json` (or the platform fallbacks —
see §5). sessium never deletes from the remote — with exactly one
exception (§8): after a replacement object is confirmed on Drive, the
superseded object under the same session id is removed.

**Object naming.** A pushed transcript lands as
`<sid>-<rawmd5>.jsonl.gz`, where `<rawmd5>` is the md5 of the
UNCOMPRESSED transcript, computed before compressing and embedded in the
name. This keeps classification in the raw domain: Python's and .NET's
gzip streams differ byte-for-byte, so a hash of the wire bytes could
never be compared across platforms — the raw md5 can. Parse rule (both
versions): strip `.jsonl.gz`, split on the LAST `-`; the trailing 32 hex
chars are the md5 (session ids are dashed uuids, md5s contain no dashes,
so this is unambiguous). Legacy plaintext `<sid>.jsonl` objects —
everything pushed before the gzip change — stay readable forever: for
them the lsjson-reported hash IS the raw md5, and they migrate
organically (the next push of a changed session writes the `.gz` name and
removes the legacy object). If a supersede-cleanup ever fails, two
objects share one id; the ledger's recorded md5 breaks the tie, else the
newest mtime — the stale object is invisible to classification and
self-heals on the next push.

Codex CLI sessions live in their own `codex/` tree, never mixed into
`projects/` — the rollout format differs from Claude transcripts and one
bad write could strand both apps. Only `~/.codex/sessions/**` rollouts are
synced: `auth.json`, sqlite DBs, `history.jsonl`, and `session_index.jsonl`
are machine-local and must never leave the box.

## 2. Munging rule

Claude Code stores a project's sessions under the project's absolute path
with every `/` replaced by `-`, leading slash included:

    /home/recoding/Kairo-v1  →  -home-recoding-Kairo-v1

Windows paths munge the same way: every `\` becomes `-` (e.g.
`C:\Users\me\repo` → `C:-Users-me-repo`). A session id is the transcript
file's stem (UUID). The ledger key is `<munged>/<session-id>` (codex keys
are namespaced — see §3).

Codex rollouts don't live in a per-project folder — they sit in
`~/.codex/sessions/YYYY/MM/DD/` — so the munged project name comes from
the rollout's own `session_meta` first line (`payload.cwd`); a rollout
without one is skipped (not a recognized session). The session id is the
uuid at the end of the rollout filename. On download, sessium synthesizes
a date-folder path `rollout-<mtime>-<uuid>.jsonl` from the Drive ModTime.

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

The md5s stored here are ALWAYS raw (uncompressed) — for `.jsonl.gz`
objects that is the name-embedded hash, for legacy objects the lsjson
hash (see §1/§8). The gzip transport changed nothing in this schema.

Codex sessions are namespaced in the same ledger as
`codex/<munged>/<session-id>`; Claude keys keep the original
`<munged>/<session-id>` shape, so existing ledgers stay valid with no
migration. A record's `project`/`id` fields are the same for both apps —
only the key prefix differs.

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
| `SESSIUM_CODEX_HOME` | Codex CLI data root | `~/.codex` |
| `SESSIUM_CONFIG` | config file path | `<xdg config>/sessium/config.json` |
| `SESSIUM_STATE` | ledger path | `<xdg state>/sessium/state.json` |
| `SESSIUM_RCLONE_BIN` | rclone binary | `rclone` on PATH |
| `SESSIUM_SYSTEMD_DIR` | user unit dir (`schedule`) | `~/.config/systemd/user` |
| `SESSIUM_COPY_TIMEOUT` | fixed transfer timeout, seconds | size-scaled, see §8 |
| `SESSIUM_RETRY_DELAY_SCALE` | multiplier on retry backoff (test knob) | `1.0` |

## 6. Conflict semantics (decided 2026-11-03)

Transcripts are never line-merged.

- `sync` resolves a conflict automatically by **newest-wins** (Drive ModTime
  vs local mtime, both UTC; tie goes to local) when no terminal is attached
  (cron, pipes). On a terminal it prompts `[L]ocal / [R]emote / [B]oth
  (newest wins) / [S]kip`; empty answer = newest-wins.
- `push` / `pull` never touch conflicts — they skip and say so.
- **The loser is never deleted.** A losing local copy is moved to
  `<claude-dir>/projects/<munged>/revert/<id>.revert-<YYYYmmdd-HHMMSS>.jsonl`
  — for codex, `<codex-home>/.sessium/projects/<munged>/revert/…`, outside
  the sessions tree on purpose: codex globs `sessions/**/*.jsonl`, so
  anything quarantined there would show up as duplicate sessions;
  a losing remote copy is downloaded there first, then overwritten.
  Sub-second collisions of the timestamp get a `-N` suffix before `.jsonl`.
- The `revert/` folder is machine-local, never synced, and is what a future
  `sessium revert <id>` will list.

## 7. Command surface (parity target)

`list`, `status`, `check`, `setup` (phase 1) · `push`, `pull`, `sync`
(phase 2) · `diff`, `resolve`, `revert`, `adopt` (phase 3) · `version`,
`log` (no id: alias for `list`; with an id: history snapshots), `open`
(phase 3.5) · `search`, `seek`, `checkout`, `gc` (Batch 4) · `schedule`,
`hook`, `setup --encrypted` (Batch 5) · `export`, `onboard` (Batch 6) ·
`resume`, `pull --adopt`, gzip transport (Batch 9).
All tree-walking commands take `--project <munged>`. Every session-facing
command takes `--app claude|codex|all` (default `all`): `status`, `list`,
`log`, `push`, `pull`, `sync`, `diff`, `resolve`, `revert`, `checkout`,
`gc`, `open`, `resume`, `export`, `search`. v1 limits: `export` and `search` parse
Claude transcripts only — with `--app codex` they fail with a clear
message — and `sync --only memory|skills` syncs Claude Code folders, so
`--app codex` there is a hard error. `adopt`, `setup`, `version`,
`schedule`, `hook`, `onboard`, and `seek` take no `--app`. `--json`
(SPEC §9) on `list`, `status`, `diff`, `search`; `--dry-run` on `push`,
`pull`, `sync`, `revert`, `adopt`, `open`, `resume`, `checkout`, `gc`; `sync`
additionally `--interactive` and `--only memory|skills` (ledger-less
two-way fast lane, per-file newest-wins, never deletes). `--quiet` on
`push`/`pull`/`sync` silences chatter (hooks/cron); errors still print.
`--debug` (alias `--verbose`) prints every rclone call and is accepted
on either side of the subcommand. Exit codes: `0` success (skips are
not failures), `1` real failures, `130` interrupted.

**Cross-machine resume (Batch 9).** Drive folders are named by the pushing
machine's absolute repo path, so `claude --resume` on another machine
lists nothing — its picker only reads folders named for THIS machine.
Two commands bridge that:

- `sessium resume [<id-prefix>] [--go] [--dry-run]` — with an id: the
  session must exist locally (else "run 'sessium pull' first"); its
  project folder is adopted (§ below) into the CURRENT directory's munged
  name when it isn't already, and the exact command is printed
  (`cd <dir> && claude --resume <full-id>`; codex needs no adoption —
  `codex resume <id>` works from anywhere). With no id: local sessions
  whose recorded repo basename matches the current directory's basename
  (the lossy-munge-proof signal) are listed and their whole folders
  adopted; then "next: claude --resume" — the native picker takes over.
  Adoption from the home directory is refused for `resume` and `open
  --adopt` (it would create a junk folder named for $HOME).
- `sessium pull --adopt` — after the pull loop, adopt-all: EVERY claude
  project the Drive knows about is adopted into this machine's equivalent
  of the repo its transcripts record (the `cwd` stamps), never the current
  directory: a recorded path that exists on this machine is used as-is;
  otherwise the foreign home prefix (`/home/<u>`, `/Users/<u>`,
  `X:\Users\<u>`) maps onto this machine's home, so `/home/recoding/proj`
  lands on `<home>/proj` — prepared for the day the repo is cloned there.
  Works from any directory, `$HOME` included (destinations never derive
  from the cwd). The one-step new-computer flow is just `sessium pull
  --adopt && claude --resume`. Folders already at this machine's name are
  no-ops; a folder whose transcripts record no repo path is left as is.
  Codex rows are skipped (no adoption needed). Implemented on the Windows
  port 2026-11-18; linux/sessium still runs the older cwd-based rule until
  ported.

Adopting the WHOLE folder is deliberate: the user gets all their sessions
for that repo in the picker, not just one. `open --adopt` shares the same
semantics — it adopts into the current directory's munged name (only when
the session's folder isn't already this machine's name for it), NOT into
the transcript's recorded cwd (which is always the pushing machine's
folder name — adopting there was a silent no-op). The printed resume line
uses the transcript's recorded cwd when that repo exists on this machine,
else the current directory.

**Encoding contract:** every `.ps1` file in the repo ships as UTF-8 **with
BOM**. Windows PowerShell 5.1 reads a BOM-less script in the ANSI codepage,
where UTF-8 punctuation (em dash = `E2 80 94`) ends in a smart-quote byte
that opens a string mid-file and detonates the parse — the box never gets
past `sessium` with no arguments. 5.1 honors the BOM; pwsh 7 reads UTF-8
either way. `sessium.cmd` stays BOM-less (cmd.exe rejects a BOM) and pure
ASCII.

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
transfer, both ledger md5s are set to the transferred copy's md5 (raw —
see §3).

**Gzip transport (Batch 9).** Session transcripts are gzip'd on the wire:

- **Upload:** md5 of the raw transcript is computed first (it goes in the
  object name), the transcript is compressed to a temp `.jsonl.gz`, and
  the temp is `copyto`'d to `<sid>-<rawmd5>.jsonl.gz`. The transfer
  timeout scales with the COMPRESSED size — the wire carries ~5–10× fewer
  bytes than the raw transcript, which is the whole point (large pushes
  were timing out). The temp is always removed.
- **Supersede:** after the replacement object is confirmed on Drive, the
  session's previous object under a DIFFERENT name (a stale `.jsonl.gz`
  or a legacy `.jsonl`) is removed with `deletefile`. This is the ONE
  deletion sessium ever performs on the remote, and it happens only after
  the new bytes are up. Failure is a warning, not an error: the stale
  object is invisible to classification (the ledger's recorded md5 wins
  the dedupe, else newest mtime — §1) and the next successful push
  retries the cleanup.
- **Download:** the remote object is `copyto`'d to a temp file, then
  magic-sniffed (`1f 8b`): gzip'd → decompressed; legacy plaintext →
  used as-is (byte-identical to the old behaviour). The decompressed
  bytes are verified: `md5(raw) ==` the object's recorded raw md5
  (name-embedded for `.jsonl.gz`, lsjson hash for legacy). A mismatch —
  or a corrupt gzip stream that has the magic but won't decompress — is
  a transfer failure (retries apply, then FAILED; nothing lands locally).
  The download timeout scales with the object's true wire size.
- **Raw is the local currency:** everything sessium writes locally —
  transcripts, revert copies, history snapshots, exports — is plaintext
  `.jsonl`. Gzip exists only on the wire. `sync --only memory|skills`
  is untouched (small config files, raw forever).

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
`list`/`status`/`diff` rows carry an additive `"app"` field
(`"claude"` or `"codex"`) naming the app that owns the row.

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
