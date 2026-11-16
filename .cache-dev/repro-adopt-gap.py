#!/usr/bin/env python3
"""Repro (CORRECTED): pull --adopt when the sessions are already in-sync
locally under a foreign folder name — second machine, pulled once before.

Fixture: machine B's SESSIUM_CLAUDE_DIR points at machine-b/.claude (the
dir itself), the session exists BOTH locally and on Drive with identical
bytes, ledger absent (bootstrap should call it in-sync, not pull)."""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path("/home/recoding/sessium")
tmp = Path(tempfile.mkdtemp(prefix="sessium-adopt-gap3-"))
proj = "-home-recoding-Kairo-v1"          # the foreign (Linux-pushed) folder
text = json.dumps({"type": "user", "message": {"content": "hey there"}}) + "\n"

# Drive pre-seeded: machine A pushed this session earlier
drive = tmp / "drive"
drive_proj = drive / "backup/projects" / proj
drive_proj.mkdir(parents=True)
(drive_proj / "s1.jsonl").write_text(text, encoding="utf-8")

# machine B: proper .claude dir; the session is ALREADY local (an earlier
# sync brought it down), identical bytes, no ledger entry
claudeB = tmp / "machine-b/.claude"
(claudeB / "projects" / proj).mkdir(parents=True)
(claudeB / "projects" / proj / "s1.jsonl").write_text(text, encoding="utf-8")

(tmp / "config.json").write_text(json.dumps(
    {"rclone_remote": "fake", "drive_folder": "backup"}))

base = os.environ.copy()
base.update({
    "SESSIUM_RCLONE_BIN": str(REPO / "tests/fake_rclone"),
    "SESSIUM_CONFIG": str(tmp / "config.json"),
    "FAKE_DRIVE_ROOT": str(drive),
})

def run(*args, cwd=None):
    e = base.copy()
    e["SESSIUM_CLAUDE_DIR"] = str(claudeB)
    e["SESSIUM_CODEX_HOME"] = str(claudeB.parent / ".codex")
    e["SESSIUM_STATE"] = str(claudeB.parent / "state.json")
    p = subprocess.run([sys.executable, str(REPO / "linux/sessium"), *args],
                       capture_output=True, text=True, env=e, cwd=cwd,
                       timeout=60)
    print(f"$ sessium {' '.join(args)}  -> rc={p.returncode}")
    print("  out:", p.stdout.strip().replace("\n", "\n       "))
    if p.stderr.strip():
        print("  err:", p.stderr.strip())
    return p

# sanity: B's classification should be in-sync (bootstrap), local visible
run("status", "--json")

# THE TEST: pull --adopt from B's repo dir — session is in-sync; does the
# foreign folder get adopted anyway?
repo_dir = tmp / "windows-repo"
repo_dir.mkdir()
run("pull", "--adopt", cwd=str(repo_dir))

adopted = list((claudeB / "projects").glob("*windows-repo*"))
print("\nadopted folder exists:", bool(adopted), adopted)
print("GAP CONFIRMED" if not adopted else "no gap: adoption happened")
