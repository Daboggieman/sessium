# sessium — User Manual

Everything you need to install, understand and drive **sessium** — git-like
version control for Claude Code and Codex CLI sessions, with Google Drive as
the remote.

For the machine-level contract (Drive layout, ledger schema, exact rules)
see [SPEC.md](../SPEC.md); for the build history see [BUILD.md](BUILD.md).

---

## 1. The mental model

Your `~/.claude/projects` tree is the **repo**, Google Drive (via rclone) is
the **remote**, and `sessium` is the CLI that pushes, pulls, diffs and
resolves sessions between them.

| git concept | sessium | what it does |
|---|---|---|
| `git remote` | `sessium setup` | one-time: pick rclone remote + Drive folder, validate, write config |
| `git status` | `sessium status` | compare local sessions vs Drive vs the last-sync ledger |
| `git log` | `sessium list` | browse sessions: project, id, date, title, size, state |
| `git pull` | `sessium pull` | download new/changed sessions from Drive |
| `git push` | `sessium push` | upload new/changed sessions to Drive |
| `git fetch` | *(implicit)* | `status` always peeks at Drive without touching local files |
| `git diff` | `sessium diff <id>` | local vs remote vs last-synced, side by side |
| `git merge` | `sessium resolve <id>` | decide a conflicted session by hand |
| `git fsck` | `sessium check` | connectivity + config + ledger self-test (`--full` audits the ledger) |
| — | `sessium sync` | the workhorse: push-what-changed AND pull-what-changed |
| — | `sessium adopt` | re-home sessions pulled for another machine's path |
| — | `sessium resume` | pick work up on this machine, whatever machine the sessions came from |

**How it works in one paragraph.** Claude Code stores every conversation in
`~/.claude/projects/<munged-repo-path>/<session-id>.jsonl` — the repo's
absolute path with every `/` replaced by `-` (`/home/me/proj` becomes
`-home-me-proj`). Claude Code's own `--resume` picker only lists sessions
under the current repo's munged name, so the whole game is getting the right
files under the right name on the machine you're sitting at. sessium syncs
that tree to Drive through rclone and keeps a per-machine **ledger**
(`~/.local/state/sessium/state.json`) that remembers each session's last
synced md5s — that's how `status` can tell *in-sync* from *push* from *pull*
from *CONFLICT*, like `git status` for your sessions.

**Why checksums, not timestamps:** Drive mtimes shift on upload; md5 is what
rclone reports for Drive files and it travels with the file.

**Two agents, one tool.** Codex CLI sessions (`~/.codex/sessions/**` rollouts)
sync the same way into their own `codex/projects/` Drive tree. Every
session-facing command takes `--app claude|codex|all` (default `all`).
Never synced, on purpose: `auth.json`, the sqlite DBs, codex's
index/history files — machine-local secrets and state.

---

## 2. Install

### Linux

```bash
curl -fsSL https://raw.githubusercontent.com/Daboggieman/sessium/master/install.sh | bash
```

or, from a clone:

```bash
git clone https://github.com/Daboggieman/sessium && cd sessium
bash setup-ubuntu.sh     # installs rclone, does the Drive sign-in, self-tests
./install.sh             # CLI + man page + bash completion to ~/.local
```

### Windows

Run `setup-windows.ps1` (installs rclone, does the Drive sign-in), then
`install.ps1` (copies `sessium.ps1` + the `sessium.cmd` shim to
`%USERPROFILE%\sessium` and adds it to your PATH).

### First check

```bash
sessium onboard          # checklist of what's set up, with next steps
sessium check            # connectivity + config + ledger self-test
```

---

## 3. Day-to-day

You will use these five commands 95% of the time:

```bash
sessium status              # what changed here / there / in conflict
sessium sync                # push AND pull what changed; prompts on conflicts
sessium list --titles       # browse sessions, newest first
sessium diff <id>           # local vs remote vs last-synced, side by side
sessium open <id>           # print (or with --go run) the resume command
```

A `status` line per session tells you what would happen:

- `in-sync` — identical everywhere; nothing to do.
- `push` — you changed it here; `sync`/`push` uploads it.
- `pull` — another machine changed it; `sync`/`pull` downloads it.
- `CONFLICT` — both sides changed since the last sync; see §6.
- `new-here` / `new-there` — exists on only one side.

**Session ids:** a prefix is enough — `sessium diff 9f8e`. Find ids with
`sessium list` (or `sessium list --titles` to see each conversation's first
real message).

**Careful dry-runs:** `--dry-run` on `push`, `pull`, `sync`, `revert`,
`adopt`, `open`, `resume`, `checkout`, `gc` prints what would happen and
touches nothing.

**Machine-readable:** `--json` on `list`, `status`, `diff`, `search` prints
one JSON document on stdout (schema in SPEC §9) — for scripts and CI.

**Silent mode:** `--quiet` on `push`/`pull`/`sync` silences chatter for
hooks/cron; errors and conflicts still print.

**Debugging:** `--verbose` (alias of `--debug`) prints every rclone call,
accepted on either side of the subcommand.

---

## 4. Syncing: push, pull, sync

```bash
sessium push                # upload new/changed sessions
sessium pull                # download new/changed sessions
sessium sync                # both directions; decides conflicts (see §6)
sessium sync --interactive  # force the conflict prompt even when piped
```

- `push` and `pull` **never touch conflicts** — they skip them and say so;
  `sync` (or `resolve`) decides.
- `sessium pull --project <munged>` scopes a run to one project folder.
- Sessions are **gzip-compressed on the wire** (typically 5–10× smaller) and
  stored on Drive as `<sid>-<rawmd5>.jsonl.gz` — the md5 of the
  *uncompressed* content rides in the object name, and every download is
  verified against it. Older plaintext objects stay readable forever.
- **Transfers survive a bad network**: a timed-out or retry-class rclone
  failure is retried twice with a short backoff, and the per-transfer
  timeout scales with the size (`max(300 s, 10 s/MB)`). Rare knobs:

  ```bash
  SESSIUM_COPY_TIMEOUT=600 sessium push    # fixed timeout override (seconds)
  SESSIUM_RETRY_DELAY_SCALE=0 ...          # collapse retry backoff (tests)
  ```

- `push`/`pull`/`sync` hold a per-machine lock so a scheduled run and a
  manual run can't transfer concurrently; a 10-minute-old lock is treated as
  a crashed run and broken with a warning.

### Memory & skills fast lane

```bash
sessium sync --only memory    # all projects' memory/ dirs, both ways
sessium sync --only skills    # ~/.claude/skills <-> config/skills
```

These small, precious folders sync **without the ledger**, per-file
newest-wins, never deletes.

---

## 5. Inspecting: list, diff, search, log

```bash
sessium list --titles                    # browse with conversation titles
sessium list --project -home-me-proj     # one repo only
sessium list --json                      # machine-readable

sessium diff <id>                        # size, messages, mtime, last lines
sessium diff <id> --messages             # + the conversation divergence:
                                         #   common prefix, what each side adds

sessium search "spaceship"               # literal search; titles outrank bodies
sessium search "hull" --semantic         # semantic via seeker, when configured
sessium search "hull" --json             # machine-readable

sessium log <id>                         # the session's history snapshots
sessium checkout <id> <seq>              # restore snapshot #seq (see log <id>)
```

`search` is literal over local transcripts — pull first to include
Drive-only sessions. For semantic search, point sessium at a
[seeker](https://github.com/Daboggieman/seeker) instance (Tailscale-only,
bearer-auth): put `"seeker_url"` and `"seeker_token"` in
`~/.config/sessium/config.json`, then run `sessium seek` once to register
the projects tree as a seeker source.

Every overwritten copy is kept **content-addressed** under the session's
`history/` folder — identical content lands under an identical name, so the
second save is a free no-op. `sessium log <id>` lists them;
`sessium checkout <id> <seq>` swaps one back in (the displaced copy is
itself snapshotted first).

---

## 6. Conflicts: never line-merged, losers always kept

A transcript is one linear conversation — merging two divergent copies
line-by-line would produce garbage. sessium's rules:

1. `sessium sync` on a **terminal** asks: `[L]ocal / [R]emote / [B]oth
   (newest wins) / [S]kip`. Empty answer = newest-wins. **Without a
   terminal** (cron, pipes, `--quiet`) it decides newest-wins by itself.
2. **The loser is never deleted.** It is kept as
   `projects/<munged>/revert/<id>.revert-<timestamp>.jsonl` (a losing local
   copy) or downloaded there (a losing remote copy), AND content-addressed
   under the session's `history/` folder.
3. `sessium revert <id>` lists the kept copies and swaps one back in.
4. `sessium gc --keep N` prunes revert/history copies beyond the N newest
   per session (`--dry-run` to preview).

So the worst case of a bad sync is: `sessium revert <id>`, pick the copy
you wanted. Nothing is ever lost silently.

---

## 7. Moving between machines (the flagship workflow)

Drive folders are named by the **pushing** machine's absolute repo path —
that's why a naive `claude --resume` on machine B lists nothing: its picker
only reads folders named for machine B. sessium has three answers.

### The one-step flow (recommended)

```bash
sessium pull --adopt         # bring this machine fully up to Drive
claude --resume              # the picker now lists them (no cd needed first)
```

`pull --adopt` is the whole-machine bring-up — no `git clone && cd` dance
required, run it from anywhere:

- every session on Drive that this machine lacks comes down into the right
  `~/.claude` / `~/.codex` directories (both created if missing);
- sessions that exist on both sides but diverged: the newest wins
  automatically, and the losing copy is kept in `revert/` — `sessium
  revert` rolls back if you change your mind. Nothing is ever overwritten
  irrecoverably;
- afterwards every claude session folder is re-homed to this machine's
  equivalent of the repo its transcript records (the `cwd` stamps): a repo
  that exists here at the same path is used as-is, otherwise
  `/home/<you>/proj` (or `C:\Users\<you>\proj`) lands on `<home>/proj` —
  ready for the day you clone the repo there.

Plain `pull` stays conservative: it downloads but leaves conflicted
sessions for `sync`/`resolve` to decide.

### `sessium resume` — pick up one session, or this repo's sessions

```bash
sessium resume <id-prefix>   # adopt that session's folder, print the command
sessium resume <id> --go     # ...and launch claude --resume immediately
sessium resume               # no id: match THIS repo by name across machines
```

- With an id: the session must exist locally (`sessium pull` first if not);
  its whole project folder is adopted into the current directory's name
  (when it isn't already) and the exact command is printed:
  `cd /your/repo && claude --resume <full-id>`.
- With no id: sessium reads each local session's recorded repo path and
  matches by **basename** — a session recorded in `/home/a/repo` matches
  your `~/somewhere/repo`, because the munged folder names don't survive
  the move but the repo's *name* does. Every matching folder is adopted,
  then `next: claude --resume` hands over to the native picker.
- **Codex needs none of this** — `codex resume <id>` works from anywhere;
  `sessium resume <id>` just prints it.

### The manual path

```bash
sessium adopt -home-old-machine-repo ~/repo    # copy a folder to a new path
sessium adopt -home-old-machine-repo ~/repo --dry-run
sessium open <id> --adopt                      # adopt + print the resume line
sessium open <id> --go                         # launch it right away
```

`adopt` copies (never moves, never overwrites — differing copies are kept
BOTH). `open --adopt` re-homes into the current directory's name when the
session's folder isn't already this machine's name for it, then prints
`cd <recorded-repo-or-here> && claude --resume <id>`.

### "I just lost my laptop"

1. Clone the repo(s): `git clone … && cd repo`.
2. Install sessium + rclone, same Drive account: `bash setup-ubuntu.sh`.
3. `sessium pull --adopt`.
4. `claude --resume`. Pick up where you left off.

---

## 8. Automation

```bash
sessium schedule             # systemd user timer (Linux) / schtasks (Windows)
sessium schedule --interval 15
sessium schedule --print     # show the unit files without installing
sessium schedule --off       # remove it

sessium hook                 # Claude Code Stop hook: push --quiet after each turn
sessium hook --print         # preview without writing
sessium hook --off           # remove (only sessium's entries are touched)
```

Scheduled runs have no terminal, so conflicts resolve **newest-wins
automatically** — with the loser always kept (§6). The hook fires
`sessium push --quiet` after every session turn, so your Drive copy is
never more than one turn behind.

---

## 9. Privacy: encryption

```bash
sessium setup --encrypted
```

Wraps the Drive folder in an rclone **crypt** remote: generates a strong
password (printed once — save it), switches sessium to the encrypted remote,
and from then on everything on Drive is unreadable ciphertext. Re-push once
to migrate. The layout and every command work identically; only the wire
changes.

---

## 10. Sharing & exporting

```bash
sessium export <id>                    # one session as Markdown
sessium export --all                   # every session as Markdown
sessium export --all --html            # + static HTML viewer with index.html
sessium export <id> --out ~/notes      # choose the destination
```

Output defaults to `./sessium-export`. HTML pages escape `< > & "`, so
pasting transcripts with markup is safe. (Claude transcripts only for now —
codex rollouts have a different format.)

---

## 11. Health & housekeeping

```bash
sessium check            # six-step self-test: rclone, remote, config, ledger…
sessium check --full     # + ledger audit: dead entries, Drive orphans,
                         #   md5 spot-check on a sample of in-sync sessions
sessium onboard          # first-run report: what's set up, what to do next
sessium gc --keep 10     # prune revert/history copies (default keep 10)
sessium version
```

`check --full` is read-only and CI-friendly; a spot-check mismatch exits `1`
(that's drift the spot-check exists to catch — re-push or re-pull the
named session).

---

## 12. Troubleshooting

**`sessium pull` says "not on this machine — run 'sessium pull' first"**
You asked `resume`/`open`/`diff` for a session that exists only on Drive.
Run `sessium pull` (or `sessium pull --adopt` on a new machine), then retry.

**`claude --resume` doesn't list my pulled sessions**
The sessions landed under the *pushing* machine's folder name. Run
`sessium pull --adopt` (from anywhere — it re-homes every folder to the
repo its transcript records), or `sessium resume` from the repo directory.

**"current directory is your home folder — cd into your repo first"**
`resume`/`open --adopt` refuse to run from $HOME — they would create a
junk folder named for your home path. `cd` into the actual repo and retry.
(`pull --adopt` has no such restriction — its destinations come from the
transcripts, never the current directory.)

**A push dies with `retry 1/2 … FAILED`**
The transfer was retried twice and still failed — usually a network or
Drive hiccup, occasionally a genuinely huge transcript on a slow link. Try
again; if big pushes keep timing out, raise the ceiling with
`SESSIUM_COPY_TIMEOUT=900`. Failed transfers land nothing partial: the
ledger only records confirmed pushes.

**"cannot reach Drive" on a brand-new machine**
rclone isn't signed in yet — run `bash setup-ubuntu.sh` (Linux) or
`setup-windows.ps1` (Windows). `sessium check` verifies the whole chain.

**"ambiguous id prefix"**
Two sessions share the prefix — use a longer one. `sessium list` shows the
full ids.

**The ledger is lost/corrupt**
Nothing bad happens: you get a loud warning, the ledger restarts empty, and
the bootstrap rule re-records sessions whose local and remote copies match.
Only genuinely divergent copies would conflict — never silent data loss.

**Both copies changed and sync picked the one I didn't want**
`sessium revert <id>` lists the kept loser copies; swap one back. Every
overwritten copy is also in `history/` (`sessium log <id>`).

**Something on Drive looks broken / duplicated**
`sessium check --full` audits dead ledger entries, Drive orphans, and
live-md5 spot-checks — read-only, safe to run anytime.

---

## 13. Command reference

| Command | Purpose |
|---|---|
| `list [--titles] [--json] [--project m]` | browse sessions, newest first |
| `status [--json] [--project m]` | what changed here / there / conflicted |
| `push [--dry-run] [--quiet] [--project m]` | upload new/changed sessions |
| `pull [--dry-run] [--quiet] [--adopt] [--project m]` | download new/changed sessions; `--adopt` re-homes for this machine |
| `sync [--interactive] [--dry-run] [--quiet] [--only memory\|skills] [--project m]` | push AND pull; decides conflicts |
| `diff <id> [--messages] [--json]` | local vs remote vs last-synced |
| `resolve <id>` | decide a conflicted session by hand |
| `revert <id> [--dry-run]` | swap a kept loser copy back in |
| `checkout <id> <seq> [--dry-run]` | restore a history snapshot |
| `log [<id>]` | list sessions (no id), or a session's history |
| `search <q> [--semantic] [--json] [--limit N]` | search local transcripts |
| `seek [--name NAME]` | register the projects tree as a seeker source |
| `open <id> [--go] [--adopt] [--dry-run]` | print (or run) the resume command |
| `resume [<id>] [--go] [--dry-run]` | pick work up on this machine (adopt + resume) |
| `adopt <munged-folder> <repo-path> [--dry-run]` | re-home sessions to a path |
| `export [<id>] [--all] [--html] [--out DIR]` | write sessions out as Markdown/HTML |
| `check [--full]` | self-test; `--full` audits the ledger |
| `setup [--check-only] [--encrypted]` | installer; `--encrypted` wraps Drive in crypt |
| `schedule [--interval MIN] [--print] [--off]` | scheduled background sync |
| `hook [--print] [--off]` | Claude Code Stop hook: auto-push |
| `gc [--keep N] [--dry-run]` | prune revert/history copies |
| `onboard` | first-run checklist |
| `version` | print the version |

Every session-facing command takes `--app claude|codex|all` (default
`all`); `export`/`search` are Claude-only for now, and `--only` is a
Claude-folder concept (`--app codex` there is a hard error). Exit codes:
`0` success (skips are not failures), `1` real failures, `130`
interrupted.
