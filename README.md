# sessium

**Git-like version control for Claude Code sessions, with Google Drive as the remote.**

Back up your conversations to Google Drive and replay any session on another
machine's Claude Code, anytime — push, pull, diff and resolve sessions the way
you would code with git.

> **Status:** working CLI for Linux (Python 3, stdlib only). Windows version
> next — see `PLAN.md` for phases and `SPEC.md` for the cross-platform contract.

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

## One-time setup (each machine)

```bash
bash setup-ubuntu.sh        # installs rclone, does the Drive sign-in, self-tests
```

That's it — it writes `~/.config/sessium/config.json` and verifies the whole
path (reach Drive, upload/read round-trip). Rerun with `--check-only` to
re-verify without prompts.

## Day to day

```bash
sessium status              # what changed here / there / in conflict
sessium sync                # push AND pull what changed; prompts on conflicts
sessium list --titles       # browse sessions, newest first
sessium diff <id>           # local vs remote vs last-synced, side by side
```

`sync` on a schedule: `crontab -e` and add
`0 * * * * $HOME/.local/bin/sessium sync >> $HOME/sessium-sync.log 2>&1`
(no terminal attached → conflicts resolve newest-wins automatically, and the
loser is always kept as a revert copy).

Push or pull only: `sessium push` / `sessium pull` — both SKIP conflicts, like
git refusing a push over divergence.

Browse what's on Drive: at drive.google.com in the `claude-backup` folder, or
`rclone lsf gdrive:claude-backup/projects`.

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

## Conflict semantics

Sessions are never line-merged — a transcript is one linear conversation. When
both machines changed the same session:

- `sessium sync` (or `resolve`) asks on a terminal: `[L]ocal / [R]emote /
  [B]oth (newest wins) / [S]kip`. No terminal (cron, pipes) → newest-wins.
- **The loser is never deleted** — it's kept as
  `projects/<munged>/revert/<id>.revert-<timestamp>.jsonl` for
  `sessium revert <id>` to swap back.
- `push` / `pull` never touch conflicts — they skip and say so.

## Files here

- `linux/sessium` — the Linux CLI (installed to `~/.local/bin/sessium` by
  `install.sh`)
- `tests/` — hermetic test suite; `python3 tests/run_tests.py` (fake rclone,
  fake two-machine Drive, nothing touches your real `~/.claude`)
- `setup-ubuntu.sh` / `setup-windows.ps1` — one-command interactive installers
- `SPEC.md` — the cross-platform contract (Drive layout, ledger schema, rules)
- `PLAN.md` — the build plan and where we are in it
- `archive/` — the retired `push.sh` / `pull.sh` / `restore-session.sh`,
  kept for reference
