# Contributing to sessium

Thanks for helping build "git for Claude Code sessions". This file is short
on purpose — the real rules live in [SPEC.md](SPEC.md).

## Layout

| path | what |
|---|---|
| `linux/sessium` | the whole Linux CLI — one Python file, no modules |
| `windows/sessium.ps1` | the PowerShell twin |
| `tests/test_sessium.py` | hermetic test suite (Python, cross-platform) |
| `tests/fake_rclone` | rclone stub backing the suite; unknown subcommands exit 1 on purpose |
| `tests/ci_smoke.ps1` | Windows smoke script (CI runs it) |
| `docs/` | man page, build log/tracker |
| `.github/workflows/` | CI + release |

## Ground rules

1. **SPEC.md is the contract.** Both versions read and write the same Drive
   layout, ledger format, conflict semantics and `--json` schemas. If the
   implementations disagree, SPEC wins and the code gets fixed.
2. **One file per platform.** No module splits — new code goes into the
   existing file, keeping the section comments organized.
3. **Tests stay hermetic.** No network, no real Drive, no real rclone:
   `tests/fake_rclone` + the `SESSIUM_*` env overrides are the fixture.
   Anything needing a real remote belongs in a manual checklist instead.
4. **Never delete Drive data.** Every overwritten copy is preserved
   (`revert/` quarantines, `history/` content-addressed snapshots — SPEC §10).

## Dev loop

```bash
python3 tests/run_tests.py      # the full suite
ruff check .                    # lint (config: ruff.toml, py311 target)
```

Windows parity: `pwsh ./tests/ci_smoke.ps1` — or just push; CI runs it.

## CI and releases

- **ci.yml** runs on every push/PR: Linux executes the Python suite;
  Windows syntax-checks `sessium.ps1` and runs the smoke script.
- **release.yml** runs on tags `v*`: packages a tar.gz + zip + SHA-256
  checksums and publishes a GitHub Release with generated notes.

## Commits

Keep commits small and imperative (`feat:`, `fix:`, `docs:` …). Don't commit
without running the suite first.
