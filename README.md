# sessium

**Git-like version control for Claude Code sessions, with Google Drive as the remote.**

Back up your conversations to Google Drive and replay any session on another
machine's Claude Code, anytime — push, pull, diff, search and resolve sessions
the way you would code with git.

> **Status:** Linux CLI complete (Phases 1–4 + all feature batches; 84 hermetic
> tests, CI on Linux & Windows). Windows PowerShell twin ships in parallel —
> see `SPEC.md` for the cross-platform contract, `docs/BUILD.md` for progress.

## Quick start (each machine)

One line, then sign in:

```bash
curl -fsSL https://raw.githubusercontent.com/Daboggieman/sessium/master/install.sh | bash
```

…or clone and install:

```bash
git clone https://github.com/Daboggieman/sessium && cd sessium
bash setup-ubuntu.sh     # installs rclone, does the Drive sign-in, self-tests
./install.sh             # CLI + man page + bash completion to ~/.local
```

`sessium onboard` prints a checklist of what's set up and what to run next.

## How it works

- Every conversation lives in `~/.claude/projects/<munged-repo-path>/<session-id>.jsonl`
  (the repo's absolute path with `/` replaced by `-`), next to a folder of the
  same name holding session data, plus your `memory/` directory.
- Claude Code offers `--resume` sessions based on the current repo path, so the
  only trick for another machine is putting the files where it looks.
- `sessium` syncs that tree with rclone, which talks to Google Drive directly.
  Your code repos are NOT backed up here — they live in git; clone them normally.
- A per-machine **ledger** (`~/.local/state/sessium/state.json`) remembers what
  was synced, so `sessium status` can tell in-sync from push from pull from
  CONFLICT — like `git status` for your sessions.

## Day to day

```bash
sessium status              # what changed here / there / in conflict
sessium sync                # push AND pull what changed; prompts on conflicts
sessium list --titles       # browse sessions, newest first
sessium diff <id>           # local vs remote vs last-synced, side by side
sessium diff <id> --messages  # + the conversation divergence past the common prefix
sessium search "spaceship"  # full-text search (titles outrank body hits)
sessium open <id>           # print (or with --go run) the claude --resume command
```

Machine-readable: `--json` on `list`, `status`, `diff`, `search` (schema in
SPEC §9). Careful dry-runs: `--dry-run` on `push`, `pull`, `sync`, `revert`,
`adopt`, `open`, `checkout`, `gc`. Nothing to type again? `sessium log <id>`
lists the session's history snapshots; `sessium checkout <id> <seq>` swaps one
back in.

## Automation

```bash
sessium schedule            # systemd user timer: sync every 30 min (--interval N, --off)
sessium hook                # Claude Code Stop hook: push --quiet after every session turn (--off)
```

Scheduled runs have no terminal, so conflicts resolve **newest-wins
automatically** — and the loser is always kept (see below). `schedule --print`
shows the unit files without installing.

## Search

`sessium search` is literal over local transcripts (pull first to include
Drive-only sessions). Point it at a [seeker](https://github.com/Daboggieman/seeker)
instance for semantic search:

```json
{ "seeker_url": "http://your-seeker:8080", "seeker_token": "…", "rclone_remote": "gdrive", "drive_folder": "claude-backup" }
```

…in `~/.config/sessium/config.json`, then `sessium search <q> --semantic`, and
`sessium seek` to register the projects tree as a seeker source.

## Privacy: encryption

`sessium setup --encrypted` wraps the Drive folder in an rclone **crypt**
remote: it generates a strong password (shown once — save it), switches
sessium to the encrypted remote, and from then on everything on Drive is
unreadable ciphertext. Re-push once to migrate (the plaintext copies stay
until you delete them by hand).

## Recovering on another computer

1. `bash setup-ubuntu.sh` (installs rclone, same Drive sign-in).
2. Get your code: `git clone` the repos — ideally to the SAME absolute paths as
   the original machine, then everything lines up with zero extra steps.
3. `sessium pull` — sessions come down to `~/.claude/projects/…`.
4. If repo paths match the original machine: done.
   If they differ: `sessium adopt <old-munged-folder> /new/repo/path`
   (e.g. `sessium adopt -home-recoding-crosswise ~/crosswise`) — copies the
   sessions under the new path so `claude --resume` finds them.
5. `cd` into the repo and `claude --resume` — pick the session, continue.
   (Shortcut: `sessium open <id> --go`.)

## Conflict semantics

Sessions are never line-merged — a transcript is one linear conversation. When
both machines changed the same session:

- `sessium sync` (or `resolve`) asks on a terminal: `[L]ocal / [R]emote /
  [B]oth (newest wins) / [S]kip`. No terminal (cron, pipes) → newest-wins.
- **The loser is never deleted** — it's kept as
  `projects/<munged>/revert/<id>.revert-<timestamp>.jsonl` for
  `sessium revert <id>` to swap back, AND content-addressed under the
  session's `history/` folder (SPEC §10) — every overwritten copy is
  recoverable, deduplicated by its md5.
- `push` / `pull` never touch conflicts — they skip and say so.
- Housekeeping: `sessium gc --keep N` prunes old revert/history copies.

## Memory & skills fast lane

Your cross-machine "brain" — `memory/` and `skills/` — syncs without the
ledger, per-file newest-wins, never deletes:

```bash
sessium sync --only memory    # all projects' memory dirs, both ways
sessium sync --only skills    # ~/.claude/skills <-> config/skills
```

## Export & viewer

```bash
sessium export <id>                    # one session as Markdown
sessium export --all --html            # every session as HTML + index.html viewer
```

Output goes to `./sessium-export` (override with `--out DIR`).

## Files here

- `linux/sessium` — the Linux CLI (installed to `~/.local/bin/sessium` by
  `install.sh`)
- `windows/sessium.ps1` — the Windows CLI (`sessium.cmd` shim; `install.ps1`
  copies both to `%USERPROFILE%\sessium` and adds it to your PATH)
- `tests/` — hermetic test suite; `python3 tests/run_tests.py` (fake rclone,
  fake two-machine Drive, nothing touches your real `~/.claude`)
- `setup-ubuntu.sh` / `setup-windows.ps1` — one-command interactive installers
- `SPEC.md` — the cross-platform contract (Drive layout, ledger schema, rules)
- `docs/BUILD.md` — the build tracker and where we are in it
- `CONTRIBUTING.md` — ground rules and the dev loop
- `archive/` — the retired `push.sh` / `pull.sh` / `restore-session.sh`,
  kept for reference
