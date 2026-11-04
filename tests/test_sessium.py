#!/usr/bin/env python3
"""sessium test suite (Phase 1) — stdlib unittest, fully hermetic.

Every test runs against a throwaway CLAUDE_DIR and a fake Drive built in a
temp directory, with rclone pointed at tests/fake_rclone. Nothing here
touches your real ~/.claude or any network.

Run from anywhere:   python3 tests/run_tests.py      (see run_tests.py)
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SESSIUM = REPO / "linux" / "sessium"
FAKE_RCLONE = REPO / "tests" / "fake_rclone"

# ---------------------------------------------------------------- fixtures

SESSION_WITH_TITLE = "\n".join([
    json.dumps({"type": "summary", "summary": "ignored summary line"}),
    json.dumps({"type": "user", "isMeta": True, "message": {"content": "meta text"}}),
    json.dumps({"type": "user", "message": {"content": "<command-name>/clear</command-name>"}}),
    json.dumps({"type": "user", "message": {"content": "hey, build me a spaceship"}}),
    json.dumps({"type": "assistant", "message": {"content": "ok"}}),
]) + "\n"

SESSION_WITH_BLOCKS = "\n".join([
    json.dumps({"type": "user", "message": {"content": [
        {"type": "text", "text": "first block"},
        {"type": "image", "source": {}},
        {"type": "text", "text": "second block"},
    ]}}),
]) + "\n"

SESSION_ONLY_COMMANDS = "\n".join([
    json.dumps({"type": "user", "message": {"content": "<ide_opened_file>x.py</ide_opened_file>"}}),
]) + "\n"


class Fixture:
    """Builds a fake local repo + fake Drive with known session contents."""

    def __init__(self, tmp: Path):
        self.tmp = tmp
        self.claude = tmp / "claude"
        self.drive = tmp / "drive"
        self.project = "-home-test-proj"
        (self.claude / "projects" / self.project).mkdir(parents=True)
        (self.drive / "backup" / "projects" / self.project).mkdir(parents=True)

    def write_local(self, name: str, content: str) -> Path:
        path = self.claude / "projects" / self.project / f"{name}.jsonl"
        path.write_text(content, encoding="utf-8")
        return path

    def write_remote(self, name: str, content: str) -> Path:
        path = self.drive / "backup" / "projects" / self.project / f"{name}.jsonl"
        path.write_text(content, encoding="utf-8")
        return path

    def env(self) -> dict:
        e = os.environ.copy()
        e.update({
            "SESSIUM_CLAUDE_DIR": str(self.claude),
            "SESSIUM_RCLONE_BIN": str(FAKE_RCLONE),
            "SESSIUM_CONFIG": str(self.tmp / "config.json"),
            "SESSIUM_STATE": str(self.tmp / "state.json"),
            "FAKE_DRIVE_ROOT": str(self.drive),
        })
        # config.json: remote name is irrelevant to the stub, folder must match
        Path(self.tmp / "config.json").write_text(json.dumps({
            "rclone_remote": "fake", "drive_folder": "backup",
        }))
        return e


def run_sessium(env: dict, *args, stdin_text=None):
    return subprocess.run(
        [sys.executable, str(SESSIUM), *args],
        capture_output=True, text=True, env=env, timeout=60,
        input=stdin_text,
    )


# ---------------------------------------------------------------- unit tests

class UnitTests(unittest.TestCase):
    """Direct tests of helper functions, imported from the script."""

    @classmethod
    def setUpClass(cls):
        # the script has no .py extension, so name an explicit source loader
        import importlib.util
        from importlib.machinery import SourceFileLoader
        loader = SourceFileLoader("sessium_mod", str(SESSIUM))
        spec = importlib.util.spec_from_loader("sessium_mod", loader)
        cls.mod = importlib.util.module_from_spec(spec)
        loader.exec_module(cls.mod)

    def test_munge(self):
        self.assertEqual(self.mod.munge("/home/u/Repo"), "-home-u-Repo")
        self.assertEqual(self.mod.munge("/x"), "-x")

    def test_human_size(self):
        self.assertEqual(self.mod.human_size(500), "500B")
        self.assertEqual(self.mod.human_size(1024), "1.0KB")
        self.assertEqual(self.mod.human_size(3 * 1024 * 1024), "3.0MB")

    def test_parse_rclone_time_variants(self):
        from datetime import datetime, timezone
        self.assertEqual(self.mod.parse_rclone_time("2026-11-03T22:50:00.123456789Z"),
                         datetime(2026, 11, 3, 22, 50, 0, 123456, tzinfo=timezone.utc))
        # a +01:00 offset must survive parsing (converted to UTC), not be sliced off
        self.assertEqual(self.mod.parse_rclone_time("2026-11-03T23:50:00+01:00"),
                         datetime(2026, 11, 3, 22, 50, tzinfo=timezone.utc))
        self.assertIsNone(self.mod.parse_rclone_time(""))
        self.assertIsNone(self.mod.parse_rclone_time("garbage"))

    def test_extract_text(self):
        self.assertEqual(self.mod.extract_text("plain"), "plain")
        self.assertEqual(self.mod.extract_text([
            {"type": "text", "text": "a"}, {"type": "image"}, {"type": "text", "text": "b"},
        ]), "a b")
        self.assertEqual(self.mod.extract_text(None), "")

    def test_session_title_skips_noise(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "s.jsonl"
            p.write_text(SESSION_WITH_TITLE, encoding="utf-8")
            self.assertEqual(self.mod.session_title(p), "hey, build me a spaceship")
            p.write_text(SESSION_ONLY_COMMANDS, encoding="utf-8")
            self.assertEqual(self.mod.session_title(p), "")


# ------------------------------------------------------------ command tests

class CommandTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.fx = Fixture(Path(self._tmp.name))

    def tearDown(self):
        self._tmp.cleanup()

    def test_status_all_states(self):
        self.fx.write_local("aaa-same", SESSION_WITH_TITLE)
        self.fx.write_remote("aaa-same", SESSION_WITH_TITLE)      # in-sync (bootstrap)
        self.fx.write_local("bbb-local", SESSION_ONLY_COMMANDS)   # new-here
        self.fx.write_remote("ccc-remote", SESSION_WITH_BLOCKS)   # new-there
        self.fx.write_local("ddd-diverged", SESSION_WITH_TITLE)
        self.fx.write_remote("ddd-diverged", SESSION_ONLY_COMMANDS)  # conflict
        proc = run_sessium(self.fx.env(), "status")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        for state in ("in-sync: 1", "new-here: 1", "new-there: 1", "CONFLICT: 1"):
            self.assertIn(state, proc.stdout)

    def test_status_remote_unreachable_stays_local(self):
        self.fx.write_local("aaa", SESSION_WITH_TITLE)
        env = self.fx.env()
        env["SESSIUM_RCLONE_BIN"] = "/bin/false"  # every rclone call fails
        proc = run_sessium(env, "status")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("local-only view", proc.stderr)
        self.assertIn("new-here: 1", proc.stdout)

    def test_list_titles(self):
        self.fx.write_local("aaa", SESSION_WITH_TITLE)
        proc = run_sessium(self.fx.env(), "list", "--titles")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("hey, build me a spaceship", proc.stdout)
        self.assertIn(self.fx.project, proc.stdout)

    def test_list_project_filter(self):
        self.fx.write_local("aaa", SESSION_WITH_TITLE)
        # space form: the munged name starts with '-', argparse would eat it
        # as a flag unless preprocess_argv rewrites it
        proc = run_sessium(self.fx.env(), "list", "--project", "-nope")
        self.assertEqual(proc.returncode, 1, proc.stderr)
        proc = run_sessium(self.fx.env(), "list", "--project=-nope")
        self.assertEqual(proc.returncode, 1, proc.stderr)
        # a name that matches must list its project and succeed
        proc = run_sessium(self.fx.env(), "list", "--project", self.fx.project)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn(self.fx.project, proc.stdout)

    def test_check_passes_against_fake_drive(self):
        self.fx.write_remote("aaa", SESSION_WITH_TITLE)
        proc = run_sessium(self.fx.env(), "check")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("remote 'fake' reachable", proc.stdout)
        self.assertIn("1 project(s), 0 session(s)", proc.stdout)

    def test_check_fails_without_drive(self):
        env = self.fx.env()
        os.rmdir(self.fx.drive / "backup" / "projects" / self.fx.project)  # leave partial
        # remove the whole drive root so even the remote root is gone
        import shutil
        shutil.rmtree(self.fx.drive)
        proc = run_sessium(env, "check")
        self.assertEqual(proc.returncode, 1)

    def test_check_reports_session_counts(self):
        self.fx.write_local("aaa", SESSION_WITH_TITLE)
        self.fx.write_local("bbb", SESSION_ONLY_COMMANDS)
        proc = run_sessium(self.fx.env(), "check")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("1 project(s), 2 session(s)", proc.stdout)


# --------------------------------------------------- two-machine sync tests

PROJ = "-home-test-proj"


class SyncTests(unittest.TestCase):
    """PLAN §7 Phase 2 verification: a scripted two-machine simulation.
    Machines A and B each have their own fake ~/.claude and ledger but share
    one fake Drive; every sessium run happens through the real CLI."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.drive = self.tmp / "drive"
        (self.drive / "backup" / "projects" / PROJ).mkdir(parents=True)
        self.a = self._machine("a")
        self.b = self._machine("b")
        (self.tmp / "config.json").write_text(json.dumps({
            "rclone_remote": "fake", "drive_folder": "backup"}), encoding="utf-8")

    def tearDown(self):
        self._tmp.cleanup()

    def _machine(self, name: str) -> dict:
        claude = self.tmp / f"machine-{name}" / ".claude"
        (claude / "projects" / PROJ).mkdir(parents=True, exist_ok=True)
        return {"claude": claude, "state": self.tmp / f"machine-{name}" / "state.json"}

    def env(self, machine: dict) -> dict:
        e = os.environ.copy()
        e.update({
            "SESSIUM_CLAUDE_DIR": str(machine["claude"]),
            "SESSIUM_STATE": str(machine["state"]),
            "SESSIUM_RCLONE_BIN": str(FAKE_RCLONE),
            "SESSIUM_CONFIG": str(self.tmp / "config.json"),
            "FAKE_DRIVE_ROOT": str(self.drive),
        })
        return e

    def local_file(self, machine: dict, sid: str) -> Path:
        return machine["claude"] / "projects" / PROJ / f"{sid}.jsonl"

    def drive_file(self, sid: str) -> Path:
        return self.drive / "backup" / "projects" / PROJ / f"{sid}.jsonl"

    def revert_files(self, machine: dict, sid: str) -> list:
        d = machine["claude"] / "projects" / PROJ / "revert"
        return sorted(d.glob(f"{sid}.revert-*")) if d.is_dir() else []

    def ledger(self, machine: dict) -> dict:
        return json.loads(machine["state"].read_text(encoding="utf-8"))

    def _baseline_conflict(self):
        """A pushes a session; B pulls; both edit. Whoever pushes LAST owns
        the newer Drive mtime."""
        self.local_file(self.a, "aaa").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        self.assertEqual(run_sessium(self.env(self.a), "push").returncode, 0)
        self.assertEqual(run_sessium(self.env(self.b), "pull").returncode, 0)

    def test_push_then_pull_roundtrip(self):
        self.local_file(self.a, "aaa").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        p = run_sessium(self.env(self.a), "push")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(self.drive_file("aaa").is_file())
        self.assertIn(f"{PROJ}/aaa", self.ledger(self.a)["sessions"])
        p = run_sessium(self.env(self.b), "pull")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.local_file(self.b, "aaa").read_text(encoding="utf-8"),
                         SESSION_WITH_TITLE)
        p = run_sessium(self.env(self.b), "status")
        self.assertIn("in-sync: 1", p.stdout)

    def test_bootstrap_records_without_prompt(self):
        # identical copies everywhere, no ledger on either machine yet
        for m in (self.a, self.b):
            self.local_file(m, "aaa").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        self.drive_file("aaa").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        p = run_sessium(self.env(self.a), "sync")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("in-sync: 1", p.stdout)
        self.assertIn(f"{PROJ}/aaa", self.ledger(self.a)["sessions"])
        self.assertEqual(self.revert_files(self.a, "aaa"), [])   # nothing quarantined

    def test_local_edit_syncs_up(self):
        self._baseline_conflict()          # just the baseline here
        self.local_file(self.a, "aaa").write_text(
            SESSION_WITH_TITLE + "A's extra line\n", encoding="utf-8")
        p = run_sessium(self.env(self.a), "sync")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("pushed: 1", p.stdout)
        self.assertEqual(self.drive_file("aaa").read_text(encoding="utf-8"),
                         SESSION_WITH_TITLE + "A's extra line\n")
        p = run_sessium(self.env(self.b), "sync")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.local_file(self.b, "aaa").read_text(encoding="utf-8"),
                         SESSION_WITH_TITLE + "A's extra line\n")

    def test_conflict_remote_newer_wins(self):
        self._baseline_conflict()
        self.local_file(self.a, "aaa").write_text("A was here\n", encoding="utf-8")  # T1
        self.local_file(self.b, "aaa").write_text("B was here\n", encoding="utf-8")
        self.assertEqual(run_sessium(self.env(self.b), "push").returncode, 0)  # T2 > T1
        p = run_sessium(self.env(self.a), "sync")     # non-tty → newest wins
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("remote wins", p.stdout)
        self.assertEqual(self.local_file(self.a, "aaa").read_text(encoding="utf-8"),
                         "B was here\n")
        rev = self.revert_files(self.a, "aaa")
        self.assertEqual(len(rev), 1)
        self.assertEqual(rev[0].read_text(encoding="utf-8"), "A was here\n")
        entry = self.ledger(self.a)["sessions"][f"{PROJ}/aaa"]
        self.assertEqual(entry["local_md5"], entry["remote_md5"])

    def test_conflict_local_newer_wins(self):
        self._baseline_conflict()
        self.local_file(self.b, "aaa").write_text("B was here\n", encoding="utf-8")
        self.assertEqual(run_sessium(self.env(self.b), "push").returncode, 0)  # T1
        self.local_file(self.a, "aaa").write_text("A was here\n", encoding="utf-8")  # T2 > T1
        p = run_sessium(self.env(self.a), "sync")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("local wins", p.stdout)
        self.assertEqual(self.drive_file("aaa").read_text(encoding="utf-8"),
                         "A was here\n")
        rev = self.revert_files(self.a, "aaa")
        self.assertEqual(len(rev), 1)
        self.assertEqual(rev[0].read_text(encoding="utf-8"), "B was here\n")

    def test_conflict_interactive_choice(self):
        self._baseline_conflict()
        self.local_file(self.b, "aaa").write_text("B was here\n", encoding="utf-8")
        self.assertEqual(run_sessium(self.env(self.b), "push").returncode, 0)  # newer
        self.local_file(self.a, "aaa").write_text("A was here\n", encoding="utf-8")
        p = run_sessium(self.env(self.a), "sync", "--interactive", stdin_text="L\n")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("local wins", p.stdout)
        self.assertEqual(self.drive_file("aaa").read_text(encoding="utf-8"),
                         "A was here\n")
        rev = self.revert_files(self.a, "aaa")       # losing REMOTE copy preserved
        self.assertEqual(len(rev), 1)
        self.assertEqual(rev[0].read_text(encoding="utf-8"), "B was here\n")

    def test_conflict_interactive_skip(self):
        self._baseline_conflict()
        self.local_file(self.a, "aaa").write_text("A was here\n", encoding="utf-8")
        self.local_file(self.b, "aaa").write_text("B was here\n", encoding="utf-8")
        self.assertEqual(run_sessium(self.env(self.b), "push").returncode, 0)
        p = run_sessium(self.env(self.a), "sync", "--interactive", stdin_text="S\n")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("skipped: 1", p.stdout)
        self.assertEqual(self.local_file(self.a, "aaa").read_text(encoding="utf-8"),
                         "A was here\n")             # nothing touched
        # the ledger still says what it said after the baseline push: local
        # md5 = the original content, NOT A's unsynced edit
        import hashlib
        baseline_md5 = hashlib.md5(SESSION_WITH_TITLE.encode()).hexdigest()
        entry = self.ledger(self.a)["sessions"][f"{PROJ}/aaa"]
        self.assertEqual(entry["local_md5"], baseline_md5)

    def test_push_skips_conflict(self):
        self._baseline_conflict()
        self.local_file(self.a, "aaa").write_text("A was here\n", encoding="utf-8")
        self.drive_file("aaa").write_text("B was here\n", encoding="utf-8")
        p = run_sessium(self.env(self.a), "push")
        self.assertEqual(p.returncode, 0, p.stderr)      # skipping isn't failing
        self.assertIn("conflicts skipped: 1", p.stdout)
        self.assertEqual(self.drive_file("aaa").read_text(encoding="utf-8"),
                         "B was here\n")                 # Drive untouched

    def test_ledger_corrupt_starts_fresh(self):
        self.local_file(self.a, "aaa").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        self.assertEqual(run_sessium(self.env(self.a), "push").returncode, 0)
        Path(self.a["state"]).write_text("{not json", encoding="utf-8")
        p = run_sessium(self.env(self.a), "sync")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("unreadable", p.stderr)            # loudly warned
        self.assertIn("in-sync: 1", p.stdout)            # bootstrap re-recorded
        self.assertIn(f"{PROJ}/aaa", self.ledger(self.a)["sessions"])

    def test_status_ledger_states(self):
        self.local_file(self.a, "aaa").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        self.local_file(self.a, "bbb").write_text(SESSION_ONLY_COMMANDS, encoding="utf-8")
        self.assertEqual(run_sessium(self.env(self.a), "push").returncode, 0)
        self.local_file(self.a, "aaa").write_text("A edited\n", encoding="utf-8")
        self.drive_file("bbb").write_text("B edited\n", encoding="utf-8")
        p = run_sessium(self.env(self.a), "status")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("push: 1", p.stdout)
        self.assertIn("pull: 1", p.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
