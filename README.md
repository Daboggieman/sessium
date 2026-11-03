# sessium

**Git-like version control for Claude Code sessions, with Google Drive as the remote.**

Back up your conversations to Google Drive and replay any session on another
machine's Claude Code, anytime — push, pull, diff and resolve sessions the way
you would code with git.

> **Status:** early. The setup + sync scripts below work today; the full
> `sessium` CLI is being built (see `PLAN.md`).

## How it works

- Every conversation lives in `~/.claude/projects/<munged-repo-path>/<session-id>.jsonl`
  (the repo's absolute path with `/` replaced by `-`), next to a folder of the
  same name holding session data, plus your `memory/` directory.
- Claude Code offers `--resume` sessions based on the current repo path, so the
  only trick for another machine is putting the files where it looks.
- These scripts sync that folder (plus settings, skills, and your memory) with
  rclone, which talks to Google Drive directly. Your code repos are NOT backed
  up here — they live in git; clone them normally.

## One-time setup (each machine)

1. Install rclone:  `sudo apt install rclone`
2. Connect your Drive:  `rclone config`, then:
   - `n` (new remote)
   - name: `gdrive`
   - Storage: type `drive` (Google Drive)
   - client_id / client_secret / scope / service_account_file: press Enter for all
   - Edit advanced config: `n`
   - Auto config: `y` → a browser opens, sign in to the Google account you want
   - team drive: `n`
   - `y` to confirm, `q` to quit
3. First push (this machine): `~/sessium/push.sh`

Step 1–3 in one go: run `bash setup-ubuntu.sh` — it installs rclone, asks for
and validates your remote name and folder, does the sign-in, writes the config
and auto-tests it.

## Day to day

- After work sessions: `~/sessium/push.sh`
  (never deletes from Drive, so it's safe to run anytime)
- To automate, add an hourly sync: `crontab -e` and add
  `0 * * * * $HOME/sessium/push.sh >> $HOME/sessium/push.log 2>&1`
- Browse what's on Drive: at drive.google.com in the `claude-backup` folder, or
  `rclone lsf gdrive:claude-backup/projects`

## Recovering on another computer

1. `sudo apt install rclone` and run `rclone config` with the SAME remote
   name (`gdrive`) as above — or just run `bash setup-ubuntu.sh`.
2. Get your code: `git clone` the repos (ideally to the SAME absolute paths as
   the original machine — e.g. keep the username the same — then everything
   lines up with zero extra steps).
3. `~/sessium/pull.sh`  (fetch the scripts + all sessions)
4. If repo paths match the original machine: done.
   If they differ: `~/sessium/restore-session.sh -home-recoding-crosswise ~/crosswise`
   (first arg = folder name from the old machine, second = where the repo lives now)
5. `cd` into the repo and `claude --resume` — pick the session, continue.

Bootstrap shortcut on a fresh machine (before step 3, if you don't have these
scripts yet): after `rclone config`, fetch them straight from Drive with
`rclone copy gdrive:claude-backup/sessium ~/sessium`.

## Setup scripts

- `setup-ubuntu.sh` — interactive: installs rclone, collects + validates your
  remote name and folder, runs the Google sign-in, writes the config, then
  auto-tests (reach Drive, create folder, upload/read/delete round-trip).
  Also updates `config.sh` with your choices. Rerun anytime with `--check-only`
  to re-verify an existing setup without prompts.
- `setup-windows.ps1` — same thing for Windows (winget or direct download,
  PowerShell 5.1+). Run with
  `powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1`

## Files here

- `config.sh` — what gets synced; edit to add more
- `push.sh` / `pull.sh` — sync to/from Drive (copy-only, nothing is ever deleted)
- `restore-session.sh` — rehomes sessions when repo paths differ between machines
- `setup-ubuntu.sh` / `setup-windows.ps1` — one-command interactive installers
