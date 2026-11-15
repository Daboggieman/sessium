#!/usr/bin/env python3
"""One-shot: build .cache-dev/smoke-local2.ps1 from tests/ci_smoke.ps1 by
rewriting Windows path literals to forward slashes (Linux mirror run of the
Windows engine). Gitignored scratch — regenerated on demand."""
from pathlib import Path

src = Path("/home/recoding/sessium/tests/ci_smoke.ps1").read_text(encoding="utf-8")

# longest-first: every backslash PATH literal in the smoke, to forward
# slashes. Regex backslashes (\d \[ \s \( \S \+ \.) are untouched.
lits = [
    r"backup\projects\$proj\memory\note.md",
    r"backup\projects\$proj\memory\drive-note.md",
    r"backup\config\skills\my-skill.md",
    r".sessium\projects\$codexProj\revert",
    r"projects\$proj\aaa.jsonl",
    r"projects\$proj\aaa\history",
    r"projects\$proj\legacy.jsonl",
    r"projects\-home-oldmachine-proj",
    r"projects\$proj\fresh.jsonl",
    r"projects\$proj\revert",
    r"projects\$proj\memory",
    r"backup\projects\$proj",
    r"codex\projects\$codexProj",
    r"machine-a\.claude", r"machine-b\.claude",
    r"machine-a\.codex", r"machine-b\.codex",
    r"machine-a\state.json", r"machine-b\state.json",
    r"projects\$proj",
    r"sessions\2026\11\09",
    r"skills\my-skill.md",
    r"tests\fake_rclone.cmd",
    r"windows\sessium.ps1",
]
for lit in lits:
    src = src.replace(lit, lit.replace("\\", "/"))
src = src.replace("$repo = $PSScriptRoot | Split-Path",
                  '$repo = "/home/recoding/sessium"')

out = Path("/home/recoding/sessium/.cache-dev/smoke-local2.ps1")
out.write_text(src, encoding="utf-8")
print("mirror regenerated,", len(src.splitlines()), "lines")
