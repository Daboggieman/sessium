# sessium — BUILD DOC

The living record of what is built, what is being built, and how each feature
works. PLAN.md holds the concept and the decisions; this file owns the
feature-by-feature status. One fact, one home: design detail lives here,
not in PLAN.md or README.md.

**Legend:** ✅ done · 🚧 in progress · ⬜ planned · 🪟 needs Windows parity

---

## 1. What is built (Phases 0–4, done 2026-11-03/04)

### Linux CLI (`linux/sessium`, Python 3 stdlib, single file)

| Command | What it does | Status |
|---|---|---|
| `list [--titles] [--project]` | all sessions local+remote, newest first | ✅ |
| `status [--project]` | classify every session vs ledger vs Drive | ✅ |
| `check` | 6-step connectivity/config/ledger self-test | ✅ |
| `setup` | runs setup-ubuntu.sh (rclone install + OAuth) | ✅ |
| `push` / `pull [--project]` | one-way transfer; **skips conflicts with a warning** | ✅ |
| `sync [--interactive] [--project]` | push+pull what changed; decides conflicts | ✅ |
| `diff <id>` | local vs remote vs last-synced: size, mtime, msgs, last snippet | ✅ |
| `resolve <id>` | manual conflict decision: L / R / B(newest) / S | ✅ |
| `revert <id>` | list a session's revert copies, swap one back in | ✅ |
| `adopt <munged> <path>` | rehome sessions to this machine's repo path | ✅ |

- **Ledger** (`~/.local/state/sessium/state.json`): md5-based classification,
  bootstrap rule (matching md5s + no record → in-sync silently), corrupt-ledger
  → loud warn + fresh start. Schema in SPEC.md §3.
- **Conflicts**: never line-merged; newest-wins automatic off-terminal,
  `[L/R/B/S]` prompt on a terminal; loser always kept under
  `projects/<munged>/revert/`.
- **Tests**: 34-test hermetic suite (`tests/run_tests.py`) with fake rclone +
  two-machine simulation. All green 2026-11-04.

### Windows port (`windows/sessium.ps1`, PowerShell 5.1+)

- Same command surface, same ledger, same Drive layout (SPEC.md contract). ✅ code
- `sessium.cmd` shim + `install.ps1` (%USERPROFILE%\sessium + user PATH). ✅
- Verified structurally (bracket balance, strict-mode audit, 5.1-compat review:
  no `.ArgumentList`, no `>N` format specs, safe JSON property access).
- ⬜ **Runtime verification on a real Windows box / CI** — see §2 CI.

### Installers & setup

- `setup-ubuntu.sh`: rclone install, OAuth (deletes the old remote section only
  AFTER the new token validates), writes `~/.config/sessium/config.json`, self-test.
- `setup-windows.ps1`: same flow for Windows.
- `install.sh` / `uninstall.sh` (Linux): copy one file to `~/.local/bin`.

### Archive

- `push.sh`, `pull.sh`, `restore-session.sh` → `archive/`, headed "RETIRED —
  use sessium X". Kept for reference only.

---

## 2. Work order (approved 2026-11-04) — batches, dependency-ordered

### Batch 1 — repo structure & docs ✅

- ✅ `docs/sessium.1` man page (groff; `install.sh` installs it to `~/.local/share/man/man1`)
- ✅ Shell completions: `completions/sessium.bash`, `.zsh`, `.fish`; wired into install.sh
- ✅ `makefile`: `test`, `lint`, `man`, `completions`, `archive` targets
- ✅ `tests/README.md` — explains the hermetic design (fake rclone, two-machine sim)
- ✅ README.md rewrite around the full command surface
- ✅ This file (docs/BUILD.md) (created with this work order)

### Batch 2 — GitHub Actions CI *(top-3 pick #1)* ✅

- ✅ `.github/workflows/ci.yml`:
  - **linux job**: `python3 tests/run_tests.py` (the full suite — 84 tests green)
  - **windows job**: `pwsh` — parse-check `sessium.ps1`, then a **hermetic smoke
    run** reusing `tests/fake_rclone` (it's Python — works on Windows) with the
    same SESSIUM_* env overrides: status, push, pull, sync, conflict, diff
    round-trip against a fake Drive on the runner. This is real Windows
    verification without owning a box.
- ⬜ README badge once first run is green.

### Batch 3 — CLI foundations (unlock the rest)

- ⬜ `--json` on `list`, `status`, `diff`, `search` — documented schema (SPEC §9);
  every feature below that consumes output (web viewer, scripts) goes through it
- ⬜ `--dry-run` on `push`, `pull`, `sync`, `revert`, `adopt` — print exact
  actions, touch nothing; exit 0
- ⬜ `sessium version`
- ⬜ `sessium log` — git-style alias for `list` (the metaphor, kept)
- ⬜ `sessium open <id>` — resume helper: resolve session → project path,
  print (and optionally spawn) `cd <repo> && claude --resume <id>`;
  `--adopt` chains the rehome when paths don't match
- ⬜ Lockfile in state dir for push/pull/sync (cron + manual collision guard)

### Batch 3 — CLI foundations (unlock the rest) ✅

- ✅ `--json` on `list`, `status`, `diff` (and `search`) — documented schema (SPEC §9);
  every feature below that consumes output (web viewer, scripts) goes through it
- ✅ `--dry-run` on `push`, `pull`, `sync`, `revert`, `adopt`, `open` — print exact
  actions, touch nothing; exit 0
- ✅ `sessium version`
- ✅ `sessium log` — git-style alias for `list` (the metaphor, kept)
- ✅ `sessium open <id>` — resume helper: resolve session → project path (via the
  transcript's `cwd` stamps), print (and with `--go` spawn) `cd <repo> && claude --resume <id>`;
  `--adopt` chains the rehome when paths don't match
- ✅ Lockfile in state dir for push/pull/sync (cron + manual collision guard;
  10-min stale-break; `--dry-run` never locks)

### Batch 4 — search & history ✅

- ✅ `sessium search <query> [--project] [--limit]`: staged results — title
  match > body match; scans local transcripts line-by-line (jsonl-aware:
  searches message text, not JSON syntax); `--json` per SPEC §9
- ✅ **seeker integration** *(top-3 adjacent, user-requested)*: optional
  semantic tier. Config: `seeker_url` + `seeker_token` in config.json (seeker
  is Tailscale-only, bearer-auth). `sessium seek` registers
  `~/.claude/projects` as a seeker source; `sessium search --semantic
  <q>` POSTs `/v1/search` and maps chunk hits back to session ids. stdlib
  urllib only — no new deps. Graceful "seeker not configured" when absent.
- ✅ **Merge preview**: `sessium diff <id> --messages` — parse both transcripts,
  show divergence as conversations: which messages each side added since the
  common prefix, with short snippets. (Transcripts are append-mostly; the
  common prefix IS the last-synced content.)
- ✅ **Snapshots / content-addressed history** *(top-3 adjacent)*: before any
  overwrite, the replaced Drive copy is also kept as
  `projects/<munged>/<sid>/history/<seq>-<md5[:8]>.jsonl` (content-addressed:
  identical content = identical name = free dedup). `sessium log <id>` lists
  history entries (seq, md5, size, when); `sessium checkout <id> <seq>` swaps
  one back like revert (the displaced copy is itself snapshotted). Ledger
  untouched by history writes.
- ✅ **Time-travel safety**: `sessium gc [--keep N]` — prune revert/ + history/
  copies beyond N most recent per session (default 10); never touches canonical
  files; `--dry-run` supported.
- ✅ **Deep `sessium check --full`**: read-only ledger audit on top of the
  six-step self-test — dead ledger entries (gone from both sides),
  orphans on Drive (never synced from this machine), and an md5
  spot-check of a deterministic sample (≤10) of in-sync sessions
  (live local bytes vs live Drive hash; mismatch exits 1). SPEC §7.
- ✅ **memory/skills priority**: `sessium sync --only memory` (and `--only
  skills`) — fast lane two-way `rclone copy --update` of `projects/*/memory/`
  (and config/skills/); per-file newest-wins, never deletes, no ledger.

### Batch 5 — automation *(top-3 picks #2 and #3)* ✅

- ✅ **Scheduled sync** *(user-requested)*: `sessium schedule [--interval MIN]`
  → installs a systemd **user** timer (`~/.config/systemd/user/sessium.timer`
  + `.service`, default every 30 min; `--print` shows the units without
  installing). `sessium schedule --off` disables and removes it. The timer
  runs `sessium sync` (no tty → newest-wins, revert copies on losses); logs
  land in the systemd journal.
- ✅ **Hooks** *(user-requested, top-3 pick #2)*: `sessium hook` wires a
  Claude Code **Stop hook** into `~/.claude/settings.json` so every session
  auto-pushes when it ends (zero-touch backup). `sessium hook --off` unwinds
  it — only sessium's entries are touched. `--print` previews. Hook command:
  `sessium push --quiet` (non-interactive, never blocks the session for more
  than a few seconds; failures logged, never fatal).
- ✅ **Encryption** *(top-3 pick #3)*: `sessium setup --encrypted` → creates an
  rclone **crypt remote** `sessium-crypt` layered on the working remote
  (`<remote>:<folder>`), re-points config.json at it, keeps the same Drive
  layout underneath. Sessium code unchanged; everything on Drive becomes
  ciphertext. The generated password is shown exactly once. Existing
  plaintext data: re-push once to migrate; old plaintext copies stay until
  deleted by hand (documented in the command output + SPEC §5).

### Batch 6 — sharing & browsing ✅

- ✅ **Export** *(user-requested)*: `sessium export <id>` / `export --all
  [--html] [--out DIR]` — render transcripts to clean readable Markdown or
  HTML (isMeta/commands/ide noise stripped). Default output dir
  `./sessium-export`.
- ✅ **Web viewer** *(user-requested)*: shipped as `export --all --html` —
  per-session HTML pages + an `index.html` linking them, self-contained CSS,
  open `file://` and go. (No search box — `sessium search` covers that.)
- ✅ **Onboard** *(user-requested)*: `sessium onboard` — setup checklist:
  rclone present, encryption state, Drive reachable, sessions found, ledger
  state, timer installed, hook installed → "suggested next steps" list. Not an
  interactive wizard; it points at the exact commands.

### Batch 7 — release engineering & hygiene *(user-requested)* ✅

- ✅ Tag + **GitHub Releases** workflow (`.github/workflows/release.yml`): on
  `v*` tags, package a repo tar.gz + zip + SHA-256 checksums, publish with
  generated notes
- ✅ One-line installer doc in README: `curl -fsSL .../install.sh | bash`
- ✅ `ruff` lint pass (repo `ruff.toml`, py311 target, E/F/W/I/UP) — all checks
  pass; stdlib-only preserved
- ✅ fake_rclone kept at `tests/fake_rclone` (no `tests/lib/` move — one dir
  less); tests/README.md covers it
- ✅ CONTRIBUTING.md (ground rules, dev loop, CI/release notes, commit style)

### Windows parity (rolling)

- ✅ **Batch 3 foundations ported to `windows/sessium.ps1`** (2026-11-07):
  `version`, `log` (alias + `<id>` history listing), `open` (--go/--adopt),
  `--json` on list/status/diff via a hand-rolled PS 5.1 serializer that
  mirrors Python's `json.dumps(indent=2, sort_keys=True)` byte-for-byte,
  `--dry-run` on push/pull/sync/revert/adopt/open, `--quiet`, and the
  `sync.lock` transfer lockfile. Smoke run (`tests/ci_smoke.ps1`) extended:
  version/json schemas/dry-run/quiet/lockfile/open + a fake_rclone.cmd shim
  so CI's Windows job can actually run the stub. Also fixed two latent
  smoke bugs (final sync of the conflict sequence ran as the wrong machine;
  Set-Content CRLF/BOM would break exact-content assertions).
- ✅ **Batch 4 ported to `windows/sessium.ps1`** (2026-11-07): `search` (title
  > body ranking, one compound sort, --json, --semantic) + `seek`, `diff
  --messages` (common-prefix divergence, `[role, text]` preview pairs in
  JSON), history snapshots (content-addressed `<seq>-<md5[:8]>.jsonl`, written
  at all 4 conflict sites — matching Linux cmd_revert's asymmetry where only
  checkout snapshots its displaced copy), `checkout <id> <seq>` (--dry-run,
  displaced copy snapshotted, ledger local_md5 updated), `gc --keep N`
  (revert/ + history/ per-session, dry-run), `check --full` (dead ledger
  entries, orphans, md5 spot-check sample), `sync --only memory|skills`
  (two-way rclone copy --update inside the transfer lock). Smoke run extended
  to ~150 assertions: snapshot round-trip through the conflict step,
  checkout moves the chosen snapshot out (seq numbering), gc keep=1, message
  divergence vs a plain-text remote (0 parseable messages), search
  title/body/no-match/--json, unconfigured-seeker failures, deep-check happy
  path, memory/skills two-way sync including a Drive-only pull-down.
- ✅ **Batch 5 ported to `windows/sessium.ps1`** (2026-11-08, committed 897a193):
  `schedule` (Task Scheduler via `schtasks`, platform-stubbed in the smoke),
  `hook` (Claude Code Stop hook, JSON-escaped identically to Python's
  json.dumps), `setup --encrypted` (crypt remote + one-time password).
- ✅ **Batch 6 ported to `windows/sessium.ps1`** (2026-11-08): `export`
  (Markdown/HTML + index viewer, HTML escaping matching Python's
  html.escape) and `onboard` (checklist + next steps). **Windows parity is
  feature-complete** — the full smoke (180+ assertions) is green locally and
  in CI.
- 🪟 Transfer hardening (2026-11-08: size-aware timeout, engine retry,
  `--verbose`, post-crypt config fix, `FAILED:` summary wording) — done on
  both platforms, see the decisions log.

---

## 3. Decisions log (feature-era)

- 2026-11-04 — **No module split**: linux/sessium stays one file (install =
  copy one file; sibling-import fragility). Revisit only past ~2.5k lines.
- 2026-11-04 — **Search tiers**: literal grep always; semantic via seeker when
  configured. No embedding code inside sessium, ever — seeker owns that.
- 2026-11-04 — **History is content-addressed and additive**: writing history
  never mutates the ledger; snapshots are free dedup, not a second format.
- 2026-11-04 — **Scheduling/hook defaults are safe**: no-tty sync = newest-wins
  with guaranteed revert copies; hook push is quiet and non-fatal.
- 2026-11-07 — **Fresh remote is empty, not unreachable** (found on a real
  machine): lsjson rc=3 "directory not found" on a brand-new Drive is treated
  as an empty remote everywhere — push creates the folder chain. Fixed in
  `remote_sessions()`/`sync_only()` (Linux) and
  `Get-RemoteSessions`/`Invoke-SyncOnly` (Windows); regression tests both
  sides (suite + smoke step 0).
- 2026-11-07 — **The README one-liner actually works now**: `install.sh`
  survives `curl | bash` (`${BASH_SOURCE[0]:-$0}`; BASH_SOURCE is unset when
  piped and `set -u` aborted on it) and, with no checkout to install from,
  fetches the files from master into a temp dir. It also installs
  `setup-ubuntu.sh` to `~/.local/bin` so an installed `sessium setup` works
  (cmd_setup falls back to PATH lookup). uninstall.sh matches.
- 2026-11-08 — **Windows CI smoke is green and is the engine gate now**: the
  hook settings.json came out invalid JSON because `ConvertTo-JsonString`'s
  `continue` inside a `switch` clause exits only the switch (post-switch code
  still ran, doubling every escaped quote). Exclusive switch with `default`
  fixed it; the smoke now runs 180+ assertions on every CI push.
- 2026-11-08 — **Transfer hardening from a real sync's failures** (3 sessions
  lost to the fixed 300 s copyto timeout on big transcripts + 1 to rclone
  rc=6, and `--verbose` typed after the subcommand was "unrecognized"):
  size-aware transfer timeout `max(300 s, 10 s/MB)` with `SESSIUM_COPY_TIMEOUT`
  override; engine-level retry (2 attempts, 2 s/4 s backoff,
  `SESSIUM_RETRY_DELAY_SCALE` test knob) on timeouts and rclone rc 5/6/8 only —
  permanent errors (2/3/4/7) fail immediately, and copyto/copy are idempotent
  so a blind re-attempt is safe; `--verbose` accepted anywhere as a `--debug`
  alias (Python: preprocess_argv hoisting; PS: the manual parser takes flags
  anywhere). Wired at every transfer site on both platforms (upload with file
  size, download, revert copy, remote-transcript cat, memory/skills
  copy --update). Tests: 96 Linux (4 new) + a retry/verbose smoke section both
  platforms (fake rclone `SESSIUM_FAKE_FAIL_FIRST="<rc>,<count>"` injects the
  failures).
- 2026-11-08 — **Post-crypt config no longer forks the upload path**: the
  config loaders dropped `drive_folder: ""` (written by `setup --encrypted`)
  on a truthy check, so every push after encryption went to
  `<crypt>:claude-backup/` — a parallel tree — instead of the crypt root.
  Both loaders now honor present-but-empty values (SPEC §5); the fake rclone
  tolerates the leading slash that an empty folder puts after the colon
  (real rclone always did). Regression tests both sides.
- 2026-11-08 — **Transfer summary is byte-identical across platforms**: the
  Windows push/pull/sync summary said `FAILURES: N` and omitted zero counts;
  Linux (and the real incident paste) say `pushed: N   pulled: N   in-sync: N
  FAILED: N`. Fixed in `Write-TransferSummary` + the sync summary; format
  pinned in SPEC §7.
