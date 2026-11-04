# The sessium test suite

Everything here is **hermetic**: no network, no real Drive, and your real
`~/.claude` is never touched. Run it all:

```bash
python3 tests/run_tests.py          # or: make test
```

## How the isolation works

Every test builds a throwaway world in a temp directory and points sessium at
it through environment overrides (SPEC §5):

| env var | replaces |
|---|---|
| `SESSIUM_CLAUDE_DIR` | `~/.claude` — a fake projects tree |
| `SESSIUM_CONFIG` | `~/.config/sessium/config.json` |
| `SESSIUM_STATE` | `~/.local/state/sessium/state.json` (the ledger) |
| `SESSIUM_RCLONE_BIN` | `rclone` — pointed at `fake_rclone` |
| `FAKE_DRIVE_ROOT` | (stub-only) the fake Drive on disk |

The commands themselves run through the **real CLI** as a subprocess
(`python3 linux/sessium …`), not by importing it — so the tests exercise
argparse, exit codes and output formatting exactly as a user would see them.

## fake_rclone

`fake_rclone` is a Python stub that emulates the handful of rclone
subcommands sessium uses (`version`, `lsd`, `lsf`, `lsjson`, `copyto`,
`cat`) against a plain directory that mirrors the Drive folder layout.
It reports real md5s and nanosecond ModTimes like the real transport.

**It exits 1 on any command it doesn't know — deliberately.** If sessium
starts calling a new rclone subcommand, the tests fail loudly until the
stub learns it. Same discipline for new flags.

## The two-machine simulation

`SyncTests` / `Phase3Tests` build machines **A** and **B**: two fake
`~/.claude` trees and two ledgers sharing one fake Drive. Tests then script
realistic sequences — A pushes, B pulls, both edit, conflict — and assert on
content bytes, ledger state and revert copies. This is what proves the
conflict semantics (newest-wins, loser-never-deleted) end to end.

## Conventions for new tests

- Assert on **file bytes** and **ledger entries**, not just stdout — stdout
  proves intent, bytes prove behavior.
- Add fixture transcripts to the top of `test_sessium.py` as module constants.
- A new rclone subcommand in sessium ⇒ extend `fake_rclone` in the same change.
