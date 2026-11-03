# sessium — PLAN

**One-line pitch:** git for Claude Code sessions — your `~/.claude/projects`
tree is the "repo", Google Drive (via rclone) is the "remote", and `sessium`
is the CLI that pushes, pulls, diffs and resolves sessions between them.

**Status:** approved (decisions locked 2026-11-03, see §8). Phase 0 done; Phase 1 next.

---

## 1. Concept mapping (git → sessium)

| git concept | sessium command | what it actually does |
|---|---|---|
| `git remote` | `sessium init` | one-time: pick rclone remote + Drive folder, validate, write config + ledger, auto-test |
| `git status` | `sessium status` | compare local sessions vs Drive vs last-sync ledger; classify every session |
| `git log` | `sessium list` | list sessions: project, id, date, title (first user message), size, state |
| `git pull` | `sessium pull` | bring new/changed sessions from Drive down to local |
| `git push` | `sessium push` | upload new/changed sessions from local up to Drive |
| `git fetch` | *(implicit)* | `status` always peeks at Drive without touching local files |
| `git diff` | `sessium diff <id>` | local vs remote vs last-synced: size, message count, mtime, last lines |
| `git merge` | `sessium resolve <id>` | fix a conflicted session: keep local / take remote / keep both |
| `git fsck` | `sessium check` | connectivity + config + ledger self-test (today's `--check-only`) |
| *(git has no equivalent)* | `sessium sync` | the workhorse: pull-what-changed + push-what-changed, prompting on conflicts |
| *(git has no equivalent)* | `sessium adopt` | rehome sessions pulled for a different machine path so this machine can resume them |

## 2. The core mechanism — the ledger (sessium's ".git")

A per-machine JSON ledger at `~/.local/state/sessium/state.json` records, for
every synced session: its project (munged path), session id, **local md5**,
**remote md5**, and when it was last synced. On every command the ledger is
compared against reality:

```
                 local file unchanged?      remote file unchanged?
  in sync          yes                         yes
  push             NO                          yes      (you edited here → upload)
  pull             yes                         NO       (other machine → download)
  conflict         NO                          NO       (both sides changed!)
  new here         file exists, ledger has none
  new there        ledger has none, Drive has one
```

**Bootstrap rule (avoids first-run chaos):** if local and remote md5 already
match but the ledger has no record, that session is recorded as *in sync* —
no prompts, no mass-conflict on day one. Only genuinely divergent copies
conflict.

**Why checksums and not mtimes:** Drive mtimes shift on upload; md5 is what
rclone reports for Drive files (`rclone lsjson --hash`) and it travels with
the file. Sessions are append-mostly, so "changed" almost always means
"appended", but we treat files atomically regardless.

## 3. Conflict semantics — sessions are never line-merged

A session transcript is one linear conversation; a 3-way merge of two
transcripts is meaningless. sessium's rule, decided 2026-11-03:

- **Newest-wins automatically** — the most recently modified copy becomes the
  canonical session, on both sides.
- **The loser is never deleted** — it is kept as
  `<id>.revert-<timestamp>.jsonl` (local copy that lost) or downloaded to a
  `revert/` folder (remote copy that lost). This is the fallback if anything
  goes wrong, and the material for `sessium revert <id>`.
- **Interactive mode always asks first** — `sessium resolve <id>` offers
  [L]ocal / [R]emote / [B]oth for manual control; the newest-wins default
  applies when nobody is there to answer (cron, `--quiet`).
- `sessium revert <id>` lists a session's revert copies and swaps one back in
  (Phase 3).
- `memory/` files follow the same per-file treatment (small and independent).

## 4. What gets synced (unchanged from today)

```
gdrive:claude-backup/
  projects/<munged-path>/<session-id>.jsonl      ← the conversations
  projects/<munged-path>/<session-id>/...        ← session data folders
  projects/<munged-path>/memory/...              ← persistent memory
  config/settings.json, skills/, file-history/, plugins registry
```

This layout is already live on Drive (push.sh uploaded it), so sessium is
**backward compatible** with what exists — no re-upload needed.

## 5. Two native versions (the user's requirement)

| | **Linux version** | **Windows version** |
|---|---|---|
| File | `linux/sessium` | `windows/sessium.ps1` (+ `sessium.cmd` shim) |
| Language | **Python 3 stdlib only** (preinstalled on Ubuntu/Debian; no pip deps) | **PowerShell 5.1+** (preinstalled on Windows; no modules) |
| Transport | rclone via `subprocess` | rclone via `& rclone.exe` |
| Config/ledger | same JSON schemas | same JSON schemas |
| Installed by | `install.sh` → `~/.local/bin/sessium` | `install.ps1` → `%USERPROFILE%\sessium` + user PATH |

**The contract between them** lives in `SPEC.md`: the Drive layout, the
ledger schema, the munging rule, the state names. Both versions read/write
the same Drive data and the same ledger format, so a session pushed from
Linux resolves cleanly on Windows and vice versa.

Language recommendation for the Linux version: **Python, not bash** — the
ledger is real JSON state, argparse gives the git-like CLI for free, and you
know Python, so you can read every line (same reason the JS primers worked).
bash stays only for the tiny legacy shims until they retire.

## 6. Repository layout

```
sessium/
  README.md              front page (already rewritten)
  PLAN.md                this file
  SPEC.md                the cross-platform contract (drive layout, ledger schema, munging)
  linux/sessium          the Linux CLI (phases 1–3)
  windows/sessium.ps1    the Windows CLI (phase 4)
  windows/sessium.cmd    path shim
  install.sh / uninstall.sh
  setup-ubuntu.sh        (exists — rclone installer + OAuth + auto-test)
  setup-windows.ps1      (exists — same for Windows)
  tests/                 Linux unit tests with a fake-rclone stub
  examples/              sample `status` / `sync` transcripts for the docs
  archive/               retired drive-sync scripts, kept for reference
```

## 7. Build phases (each verified before the next starts)

- **Phase 0 — done-ish:** repo skeleton, moved+renamed scripts, README, PLAN, origin wired.
- **Phase 1 — Linux core:** config load/save, discover local + remote sessions, `sessium list`, `sessium status`, `sessium check` (absorbs today's connectivity tests). *Verify: real Drive round-trip against your account.*
- **Phase 2 — Linux sync engine:** ledger, `push`, `pull`, `sync`, conflict detection + interactive resolve prompt. *Verify: scripted two-machine simulation locally (fake second "machine" dir) + one real run.*
- **Phase 3 — Linux finish:** `diff`, `resolve`, `revert`, `adopt`; move `push.sh`/`pull.sh`/`restore-session.sh` into `archive/`. *Verify: same simulation, plus adopting this very session.*
- **Phase 4 — Windows version:** `windows/sessium.ps1` implementing SPEC.md. *Verify: on a Windows box (yours or a VM); here we verify syntax + dry-run paths only.*
- **Phase 5 — polish:** `--json` output for scripting, `--quiet` cron mode, shell completions, examples, screenshot-worthy README.

## 8. Decisions (made 2026-11-03)

1. **Linux implementation language: Python 3** (stdlib only). Windows version: PowerShell 5.1+.
2. **Legacy scripts → `archive/`** in the repo once sessium covers their jobs (Phase 3) — kept for reference, not deleted.
3. **Conflicts: newest-wins automatically, with a guaranteed revert copy** of the losing side (`<id>.revert-<timestamp>.jsonl`); interactive `sessium resolve` still offers manual choice; `sessium revert <id>` restores a loser (Phase 3).
