#!/usr/bin/env python3
"""sessium test suite (Phase 1) — stdlib unittest, fully hermetic.

Every test runs against a throwaway CLAUDE_DIR and a fake Drive built in a
temp directory, with rclone pointed at tests/fake_rclone. Nothing here
touches your real ~/.claude or any network.

Run from anywhere:   python3 tests/run_tests.py      (see run_tests.py)
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import UTC
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
        from datetime import datetime
        self.assertEqual(self.mod.parse_rclone_time("2026-11-03T22:50:00.123456789Z"),
                         datetime(2026, 11, 3, 22, 50, 0, 123456, tzinfo=UTC))
        # a +01:00 offset must survive parsing (converted to UTC), not be sliced off
        self.assertEqual(self.mod.parse_rclone_time("2026-11-03T23:50:00+01:00"),
                         datetime(2026, 11, 3, 22, 50, tzinfo=UTC))
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

    def test_pick_sample(self):
        pick = self.mod.pick_sample
        self.assertEqual(pick(["a", "b"], 5), ["a", "b"])          # under count: all
        self.assertEqual(pick(list(range(4)), 4), [0, 1, 2, 3])
        spread = pick(list(range(100)), 10)                        # deterministic, ordered
        self.assertEqual(spread, sorted(spread))
        self.assertEqual(len(spread), 10)
        self.assertEqual(len(set(spread)), 10)                     # no duplicates
        self.assertEqual(spread, list(range(0, 100, 10)))          # evenly spread


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

    def test_check_full_happy_path(self):
        self.fx.write_local("aaa", SESSION_WITH_TITLE)
        self.fx.write_remote("aaa", SESSION_WITH_TITLE)  # bootstrap: no ledger yet
        proc = run_sessium(self.fx.env(), "check", "--full")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("deep check (--full):", proc.stdout)
        self.assertIn("no dead entries", proc.stdout)
        self.assertIn("no orphans on Drive", proc.stdout)
        self.assertIn("spot-check: 1 session(s) verified", proc.stdout)

    def test_check_full_reports_orphans(self):
        # on Drive, never synced from this machine (the other-machine case)
        self.fx.write_remote("aaa", SESSION_WITH_TITLE)
        proc = run_sessium(self.fx.env(), "check", "--full")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("orphans on Drive", proc.stdout)

    def test_check_full_detects_dead_ledger_entries(self):
        self.fx.write_local("aaa", SESSION_WITH_TITLE)
        proc = run_sessium(self.fx.env(), "push")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        # the session vanishes from both sides afterwards
        (self.fx.claude / "projects" / self.fx.project / "aaa.jsonl").unlink()
        (self.fx.drive / "backup" / "projects" / self.fx.project / "aaa.jsonl").unlink()
        proc = run_sessium(self.fx.env(), "check", "--full")
        self.assertEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("dead ledger entries: 1", proc.stderr)

    def test_check_full_spot_check_mismatch_fails(self):
        # ledger claims both sides match, but the live copies differ —
        # exactly the drift the spot-check exists to catch
        self.fx.write_local("aaa", SESSION_WITH_TITLE)
        self.fx.write_remote("aaa", SESSION_ONLY_COMMANDS)
        state = self.fx.tmp / "state.json"
        ledger = {
            "version": 1,
            "sessions": {
                f"{self.fx.project}/aaa": {
                    "project": self.fx.project, "id": "aaa",
                    "local_md5": "same", "remote_md5": "same",
                    "last_synced": "2026-11-07T00:00:00Z",
                },
            },
        }
        state.write_text(json.dumps(ledger), encoding="utf-8")
        proc = run_sessium(self.fx.env(), "check", "--full")
        self.assertEqual(proc.returncode, 1, proc.stderr)
        self.assertIn("!= Drive md5", proc.stderr)


# --------------------------------------------------- two-machine sync tests

PROJ = "-home-test-proj"


class SyncBase(unittest.TestCase):
    """Shared two-machine fixture: machines A and B each have their own fake
    ~/.claude and ledger but share one fake Drive; every sessium run happens
    through the real CLI."""

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

class SyncTests(SyncBase):
    """Phase 2: ledger, push/pull/sync, conflict resolution."""

    def test_sync_on_fresh_remote_bootstraps(self):
        """A brand-new Drive (no projects/ folder at all) is "empty", not
        "unreachable" — regression: the rc=3 directory-not-found from lsjson
        used to kill status/push/sync with 'cannot reach Drive'."""
        shutil.rmtree(self.drive)
        p = run_sessium(self.env(self.a), "status", "--json")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIs(json.loads(p.stdout)["reachable"], True)
        self.local_file(self.a, "aaa").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        p = run_sessium(self.env(self.a), "sync")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(self.drive_file("aaa").is_file())   # folder chain created
        p = run_sessium(self.env(self.b), "pull")           # another machine pulls
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(self.local_file(self.b, "aaa").is_file())

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


class Phase3Tests(SyncBase):
    """Phase 3: diff, resolve, revert, adopt."""

    def _conflict(self):
        """Baseline + both sides edited, remote pushed last (remote newer)."""
        self._baseline_conflict()
        self.local_file(self.a, "aaa").write_text("A was here\n", encoding="utf-8")
        self.local_file(self.b, "aaa").write_text("B was here\n", encoding="utf-8")
        self.assertEqual(run_sessium(self.env(self.b), "push").returncode, 0)

    def test_diff_shows_sides_and_state(self):
        self._conflict()
        p = run_sessium(self.env(self.a), "diff", "aaa")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("CONFLICT", p.stdout)
        self.assertIn("local", p.stdout)
        self.assertIn("remote", p.stdout)
        self.assertIn("last synced", p.stdout)      # A's ledger has the baseline

    def test_diff_ambiguous_prefix(self):
        self._baseline_conflict()
        self.local_file(self.a, "aab").write_text(SESSION_ONLY_COMMANDS,
                                                  encoding="utf-8")
        p = run_sessium(self.env(self.a), "diff", "aa")
        self.assertEqual(p.returncode, 1)
        self.assertIn("ambiguous", p.stderr)

    def test_resolve_takes_remote(self):
        self._conflict()
        p = run_sessium(self.env(self.a), "resolve", "aaa", stdin_text="R\n")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("remote wins", p.stdout)
        self.assertEqual(self.local_file(self.a, "aaa").read_text(encoding="utf-8"),
                         "B was here\n")
        rev = self.revert_files(self.a, "aaa")
        self.assertEqual(len(rev), 1)
        self.assertEqual(rev[0].read_text(encoding="utf-8"), "A was here\n")

    def test_resolve_takes_local(self):
        self._conflict()
        p = run_sessium(self.env(self.a), "resolve", "aaa", stdin_text="L\n")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("local wins", p.stdout)
        self.assertEqual(self.drive_file("aaa").read_text(encoding="utf-8"),
                         "A was here\n")

    def test_resolve_not_conflicted_is_noop(self):
        self._baseline_conflict()
        p = run_sessium(self.env(self.a), "resolve", "aaa", stdin_text="L\n")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("nothing to resolve", p.stdout)

    def test_revert_swaps_back(self):
        self._conflict()
        self.assertEqual(run_sessium(self.env(self.a), "resolve", "aaa",
                                     stdin_text="R\n").returncode, 0)
        # now local == remote ("B was here"); A's copy sits in revert/
        p = run_sessium(self.env(self.a), "revert", "aaa", stdin_text="1\n")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.local_file(self.a, "aaa").read_text(encoding="utf-8"),
                         "A was here\n")             # the loser is back
        rev = self.revert_files(self.a, "aaa")       # what it replaced
        self.assertEqual(len(rev), 1)
        self.assertEqual(rev[0].read_text(encoding="utf-8"), "B was here\n")
        import hashlib
        entry = self.ledger(self.a)["sessions"][f"{PROJ}/aaa"]
        self.assertEqual(entry["local_md5"],
                         hashlib.md5(b"A was here\n").hexdigest())

    def test_revert_cancel_keeps_everything(self):
        self._conflict()
        self.assertEqual(run_sessium(self.env(self.a), "resolve", "aaa",
                                     stdin_text="R\n").returncode, 0)
        p = run_sessium(self.env(self.a), "revert", "aaa", stdin_text="q\n")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("cancelled", p.stdout)
        self.assertEqual(len(self.revert_files(self.a, "aaa")), 1)

    def test_revert_no_copies(self):
        self._baseline_conflict()
        p = run_sessium(self.env(self.a), "revert", "zzz")
        self.assertEqual(p.returncode, 1)
        self.assertIn("no revert copies", p.stderr)

    def test_adopt_copies_into_machine_path(self):
        old = "-home-oldmachine-proj"
        old_dir = self.b["claude"] / "projects" / old
        old_dir.mkdir(parents=True)
        (old_dir / "sss.jsonl").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        (old_dir / "memory").mkdir()
        (old_dir / "memory" / "MEMORY.md").write_text("# mem\n", encoding="utf-8")
        p = run_sessium(self.env(self.b), "adopt", old, "/home/other/repo")
        self.assertEqual(p.returncode, 0, p.stderr)
        new_dir = self.b["claude"] / "projects" / "-home-other-repo"
        self.assertTrue((new_dir / "sss.jsonl").is_file())
        self.assertEqual((new_dir / "memory" / "MEMORY.md").read_text(encoding="utf-8"),
                         "# mem\n")
        # adopt copies, never moves
        self.assertTrue((old_dir / "sss.jsonl").is_file())
        self.assertIn("cd /home/other/repo", p.stdout)

    def test_adopt_skips_differing_copy(self):
        old = "-home-oldmachine-proj"
        old_dir = self.b["claude"] / "projects" / old
        old_dir.mkdir(parents=True)
        (old_dir / "sss.jsonl").write_text("incoming version\n", encoding="utf-8")
        dest = self.b["claude"] / "projects" / "-home-other-repo"
        dest.mkdir(parents=True)
        (dest / "sss.jsonl").write_text("local version\n", encoding="utf-8")
        p = run_sessium(self.env(self.b), "adopt", old, "/home/other/repo")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("kept both", p.stderr)
        self.assertEqual((dest / "sss.jsonl").read_text(encoding="utf-8"),
                         "local version\n")

    def test_adopt_noop_when_path_matches(self):
        p = run_sessium(self.env(self.b), "adopt", PROJ, "/home/test/proj")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("nothing to do", p.stdout)

    def test_adopt_unknown_source_lists_folders(self):
        p = run_sessium(self.env(self.b), "adopt", "-nope", "/home/x/repo")
        self.assertEqual(p.returncode, 1)
        self.assertIn("available folders", p.stdout)


# ------------------------------------------------------- Batch 3: foundations

class Batch3Tests(SyncBase):
    """--json output, --dry-run, the transfer lock, version/log/open."""

    def test_version_subcommand(self):
        p = run_sessium(self.env(self.a), "version")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(p.stdout.startswith("sessium "), p.stdout)

    def test_log_alias_lists_like_list(self):
        self.local_file(self.a, "aaa").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        listed = run_sessium(self.env(self.a), "list")
        logged = run_sessium(self.env(self.a), "log")
        self.assertEqual(logged.returncode, 0, logged.stderr)
        self.assertEqual(listed.stdout, logged.stdout)

    def test_list_json_schema(self):
        self.local_file(self.a, "aaa").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        p = run_sessium(self.env(self.a), "list", "--json")
        self.assertEqual(p.returncode, 0, p.stderr)
        rows = json.loads(p.stdout)
        self.assertEqual(len(rows), 1)
        row = rows[0]
        for key in ("project", "id", "path", "size", "mtime"):
            self.assertIn(key, row)
        self.assertEqual(row["id"], "aaa")
        self.assertNotIn("title", row)            # --titles gates it
        p = run_sessium(self.env(self.a), "list", "--json", "--titles")
        rows = json.loads(p.stdout)
        self.assertEqual(rows[0]["title"], "hey, build me a spaceship")

    def test_status_json_schema(self):
        self.local_file(self.a, "aaa").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        self.drive_file("bbb").write_text(SESSION_ONLY_COMMANDS, encoding="utf-8")
        p = run_sessium(self.env(self.a), "status", "--json")
        self.assertEqual(p.returncode, 0, p.stderr)
        doc = json.loads(p.stdout)
        self.assertTrue(doc["reachable"])
        self.assertEqual(doc["counts"], {"new-here": 1, "new-there": 1})
        self.assertEqual(len(doc["rows"]), 2)
        by_id = {r["id"]: r for r in doc["rows"]}
        self.assertEqual(by_id["aaa"]["state"], "new-here")
        self.assertIsNone(by_id["bbb"]["local"])
        self.assertIsNone(by_id["aaa"]["last_synced"])
        self.assertRegex(by_id["aaa"]["local"]["mtime"], r"\d{4}-\d{2}-\d{2}T")

    def test_status_json_reports_unreachable(self):
        env = self.env(self.a)
        env["SESSIUM_RCLONE_BIN"] = "/bin/false"
        self.local_file(self.a, "aaa").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        p = run_sessium(env, "status", "--json")
        self.assertEqual(p.returncode, 0)
        doc = json.loads(p.stdout)
        self.assertFalse(doc["reachable"])
        self.assertEqual(doc["rows"][0]["state"], "new-here")

    def test_diff_json_after_push(self):
        self.local_file(self.a, "aaa").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        self.assertEqual(run_sessium(self.env(self.a), "push").returncode, 0)
        p = run_sessium(self.env(self.a), "diff", "aaa", "--json")
        self.assertEqual(p.returncode, 0, p.stderr)
        doc = json.loads(p.stdout)
        self.assertEqual(doc["state"], "in-sync")
        # diff counts user+assistant non-meta lines, incl. command wrappers
        self.assertEqual(doc["local"]["messages"], 3)
        self.assertEqual(doc["local"]["last"], "ok")
        self.assertIsNotNone(doc["remote"])
        self.assertEqual(doc["ledger"]["local_md5"], doc["ledger"]["remote_md5"])

    def test_dry_run_push_touches_nothing(self):
        self.local_file(self.a, "aaa").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        p = run_sessium(self.env(self.a), "push", "--dry-run")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("would push", p.stdout)
        self.assertIn("dry-run: pushed: 1", p.stdout)
        self.assertFalse(self.drive_file("aaa").exists())
        self.assertFalse(self.a["state"].exists())      # ledger untouched

    def test_dry_run_pull_touches_nothing(self):
        self.drive_file("aaa").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        p = run_sessium(self.env(self.a), "pull", "--dry-run")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("would pull", p.stdout)
        self.assertFalse(self.local_file(self.a, "aaa").exists())

    def test_dry_run_sync_describes_conflict_without_deciding(self):
        self._baseline_conflict()
        self.local_file(self.a, "aaa").write_text("A was here\n", encoding="utf-8")
        self.local_file(self.b, "aaa").write_text("B was here\n", encoding="utf-8")
        self.assertEqual(run_sessium(self.env(self.b), "push").returncode, 0)
        p = run_sessium(self.env(self.a), "sync", "--dry-run")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("would resolve", p.stdout)
        self.assertIn("remote wins", p.stdout)
        # nothing actually happened
        self.assertEqual(self.local_file(self.a, "aaa").read_text(encoding="utf-8"),
                         "A was here\n")
        self.assertEqual(self.revert_files(self.a, "aaa"), [])
        # the ledger entry is still the pre-conflict baseline push's record
        import hashlib
        entry = self.ledger(self.a)["sessions"][f"{PROJ}/aaa"]
        self.assertEqual(entry["local_md5"], entry["remote_md5"])
        self.assertNotEqual(entry["local_md5"],
                            hashlib.md5(b"A was here\n").hexdigest())

    def test_dry_run_adopt_lists_actions(self):
        old = "-home-oldmachine-proj"
        old_dir = self.a["claude"] / "projects" / old
        old_dir.mkdir(parents=True)
        (old_dir / "sss.jsonl").write_text("incoming\n", encoding="utf-8")
        (old_dir / "sss").mkdir()                       # a data folder too
        p = run_sessium(self.env(self.a), "adopt", old, "/home/test/proj",
                        "--dry-run")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("would copy sss.jsonl", p.stdout)
        self.assertIn("would copy folder sss/", p.stdout)
        self.assertFalse((self.a["claude"] / "projects" / PROJ / "sss.jsonl").exists())

    def test_lock_blocks_second_transfer(self):
        self.local_file(self.a, "aaa").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        lock = self.a["state"].parent / "sync.lock"
        lock.parent.mkdir(parents=True, exist_ok=True)
        lock.write_text("pid 1\n", encoding="utf-8")
        p = run_sessium(self.env(self.a), "push")
        self.assertEqual(p.returncode, 1)
        self.assertIn("another sessium transfer", p.stderr)
        self.assertFalse(self.drive_file("aaa").exists())
        # dry-run ignores the lock entirely
        p = run_sessium(self.env(self.a), "push", "--dry-run")
        self.assertEqual(p.returncode, 0, p.stderr)

    def test_stale_lock_is_broken(self):
        import time as _time
        self.local_file(self.a, "aaa").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        lock = self.a["state"].parent / "sync.lock"
        lock.parent.mkdir(parents=True, exist_ok=True)
        lock.write_text("pid 1 (long dead)\n", encoding="utf-8")
        old = _time.time() - 3600
        os.utime(lock, (old, old))
        p = run_sessium(self.env(self.a), "push")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("stale lock", p.stderr)
        self.assertTrue(self.drive_file("aaa").exists())
        self.assertFalse(lock.exists())                 # released after the run

    def test_lock_released_after_run(self):
        self.local_file(self.a, "aaa").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        self.assertEqual(run_sessium(self.env(self.a), "push").returncode, 0)
        lock = self.a["state"].parent / "sync.lock"
        self.assertFalse(lock.exists())
        # a second run is not blocked by the first
        self.local_file(self.a, "bbb").write_text(SESSION_ONLY_COMMANDS, encoding="utf-8")
        p = run_sessium(self.env(self.a), "push")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("pushed: 1", p.stdout)

    def test_open_prints_resume_command(self):
        sid = "ccc"
        entry = json.dumps({"type": "user", "cwd": "/home/test/proj",
                            "message": {"content": "hello"}})
        self.local_file(self.a, sid).write_text(entry + "\n", encoding="utf-8")
        p = run_sessium(self.env(self.a), "open", sid)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("cd /home/test/proj && claude --resume ", p.stdout)
        # the full id is printed, not the prefix
        self.assertIn(sid, p.stdout)

    def test_open_adopt_chains_rehome(self):
        sid = "ddd"
        old = "-home-oldmachine-proj"
        old_dir = self.a["claude"] / "projects" / old
        old_dir.mkdir(parents=True)
        entry = json.dumps({"type": "user", "cwd": "/home/test/proj",
                            "message": {"content": "hello"}})
        (old_dir / f"{sid}.jsonl").write_text(entry + "\n", encoding="utf-8")
        p = run_sessium(self.env(self.a), "open", sid, "--adopt")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("adopting sessions first", p.stdout)
        self.assertTrue((self.a["claude"] / "projects" / PROJ / f"{sid}.jsonl").is_file())
        self.assertIn(f"cd /home/test/proj && claude --resume {sid}", p.stdout)

    def test_open_requires_local_copy(self):
        self.drive_file("aaa").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        p = run_sessium(self.env(self.a), "open", "aaa")
        self.assertEqual(p.returncode, 1)
        self.assertIn("sessium pull", p.stderr)


# ------------------------------------------------------- batch 4: search

import threading  # noqa: E402
import time  # noqa: E402
from http.server import BaseHTTPRequestHandler, HTTPServer  # noqa: E402


class SeekerStub(BaseHTTPRequestHandler):
    """Tiny seeker-engine stand-in: POST /v1/search and /v1/sources."""

    last_payload = None

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        payload = json.loads(self.rfile.read(length) or b"{}")
        SeekerStub.last_payload = payload
        if self.path == "/v1/search":
            out = {"results": [{"path": f"projects/{PROJ}/aaa.jsonl",
                                "title": "stub title", "text": "stub chunk"}]}
        elif self.path == "/v1/sources":
            out = {"status": "ok"}
        else:
            self.send_response(404)
            self.end_headers()
            return
        body = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class Batch4Tests(SyncBase):
    """search/seek, history snapshots, checkout, gc, --only, diff --messages."""

    def _start_seeker(self) -> str:
        server = HTTPServer(("127.0.0.1", 0), SeekerStub)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_port}"

    def _with_seeker(self) -> dict:
        cfg_path = self.tmp / "config.json"
        cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
        cfg["seeker_url"] = self._start_seeker()
        cfg["seeker_token"] = "t0ken"
        cfg_path.write_text(json.dumps(cfg), encoding="utf-8")
        return self.env(self.a)

    def test_search_ranks_title_over_body(self):
        self.local_file(self.a, "aaa").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        body = "\n".join([
            json.dumps({"type": "user", "message": {"content": "hello there"}}),
            json.dumps({"type": "assistant", "message": {"content": "about the spaceship hull"}}),
        ]) + "\n"
        self.local_file(self.a, "bbb").write_text(body, encoding="utf-8")
        p = run_sessium(self.env(self.a), "search", "spaceship")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("2 match(es)", p.stdout)
        # title hit (aaa) outranks body hit (bbb, whose title is "hello there")
        self.assertLess(p.stdout.find("aaa"), p.stdout.find("bbb"))

    def test_search_json_schema(self):
        self.local_file(self.a, "aaa").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        p = run_sessium(self.env(self.a), "search", "spaceship", "--json")
        self.assertEqual(p.returncode, 0, p.stderr)
        rows = json.loads(p.stdout)
        self.assertEqual(len(rows), 1)
        for key in ("project", "id", "title", "snippet", "where", "mtime"):
            self.assertIn(key, rows[0])
        self.assertEqual(rows[0]["project"], PROJ)
        self.assertEqual(rows[0]["id"], "aaa")
        self.assertEqual(rows[0]["where"], "title")
        self.assertEqual(rows[0]["snippet"], "")     # title hit: no body snippet

    def test_search_no_matches(self):
        p = run_sessium(self.env(self.a), "search", "zzz-nothing")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("no matches", p.stdout)

    def test_search_semantic_requires_config(self):
        p = run_sessium(self.env(self.a), "search", "x", "--semantic")
        self.assertEqual(p.returncode, 1)
        self.assertIn("seeker not configured", p.stderr)

    def test_search_semantic_maps_hits_back(self):
        env = self._with_seeker()
        p = run_sessium(env, "search", "anything", "--semantic", "--json")
        self.assertEqual(p.returncode, 0, p.stderr)
        rows = json.loads(p.stdout)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["project"], PROJ)
        self.assertEqual(rows[0]["id"], "aaa")
        self.assertEqual(rows[0]["where"], "semantic")
        self.assertEqual(rows[0]["title"], "stub title")
        self.assertEqual(rows[0]["snippet"], "stub chunk")
        self.assertIsNone(rows[0]["mtime"])

    def test_seek_registers_source(self):
        env = self._with_seeker()
        p = run_sessium(env, "seek")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("seeker source synced", p.stdout)
        self.assertIn("seeker said: ok", p.stdout)
        self.assertEqual(SeekerStub.last_payload,
                         {"name": "sessium", "path": str(self.a["claude"] / "projects")})
        p = run_sessium(env, "seek", "--name", "custom-name")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(SeekerStub.last_payload["name"], "custom-name")

    # ------------------------------------------- history snapshots (SPEC §10)

    def _diverged_two_editors(self):
        """Baseline conflict, then both sides edit, B pushes last → when A
        syncs, remote wins and A's losing copy must land in revert/ AND
        history/."""
        self._baseline_conflict()
        self.local_file(self.a, "aaa").write_text("A was here\n", encoding="utf-8")
        self.local_file(self.b, "aaa").write_text("B was here\n", encoding="utf-8")
        self.assertEqual(run_sessium(self.env(self.b), "push").returncode, 0)
        p = run_sessium(self.env(self.a), "sync")
        self.assertEqual(p.returncode, 0, p.stderr)
        return p

    def test_conflict_snapshots_loser_to_history(self):
        p = self._diverged_two_editors()
        self.assertIn("remote wins", p.stdout)
        self.assertEqual(self.local_file(self.a, "aaa").read_text(encoding="utf-8"),
                         "B was here\n")
        self.assertEqual(len(self.revert_files(self.a, "aaa")), 1)
        hdir = self.a["claude"] / "projects" / PROJ / "aaa" / "history"
        snaps = sorted(hdir.glob("*.jsonl"))
        self.assertEqual(len(snaps), 1)
        import hashlib
        digest = hashlib.md5(b"A was here\n").hexdigest()
        self.assertEqual(snaps[0].name, f"0001-{digest[:8]}.jsonl")
        self.assertEqual(snaps[0].read_text(encoding="utf-8"), "A was here\n")

    def test_log_id_lists_history(self):
        self._diverged_two_editors()
        p = run_sessium(self.env(self.a), "log", "aaa")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("history of aaa", p.stdout)
        self.assertIn("0001-", p.stdout)
        self.assertIn("sessium checkout aaa <seq>", p.stdout)

    def test_log_id_without_history(self):
        self.local_file(self.a, "aaa").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        p = run_sessium(self.env(self.a), "log", "aaa")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("no history yet", p.stdout)

    def test_checkout_restores_snapshot(self):
        self._diverged_two_editors()
        p = run_sessium(self.env(self.a), "checkout", "aaa", "1")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.local_file(self.a, "aaa").read_text(encoding="utf-8"),
                         "A was here\n")
        # the displaced live copy is itself snapshotted; the checked-out
        # snapshot file moved in as the new live transcript
        hdir = self.a["claude"] / "projects" / PROJ / "aaa" / "history"
        snaps = sorted(hdir.glob("*.jsonl"))
        self.assertEqual(len(snaps), 1)
        self.assertEqual(snaps[0].read_text(encoding="utf-8"), "B was here\n")
        # ledger reflects the on-purpose local change; remote untouched
        entry = self.ledger(self.a)["sessions"][f"{PROJ}/aaa"]
        import hashlib
        self.assertEqual(entry["local_md5"],
                         hashlib.md5(b"A was here\n").hexdigest())
        self.assertEqual(entry["remote_md5"],
                         hashlib.md5(b"B was here\n").hexdigest())

    def test_checkout_dry_run(self):
        self._diverged_two_editors()
        p = run_sessium(self.env(self.a), "checkout", "aaa", "1", "--dry-run")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("would restore", p.stdout)
        self.assertEqual(self.local_file(self.a, "aaa").read_text(encoding="utf-8"),
                         "B was here\n")
        hdir = self.a["claude"] / "projects" / PROJ / "aaa" / "history"
        self.assertEqual(len(list(hdir.glob("*.jsonl"))), 1)

    def test_checkout_unknown_seq_lists_available(self):
        self._diverged_two_editors()
        p = run_sessium(self.env(self.a), "checkout", "aaa", "9")
        self.assertEqual(p.returncode, 1)
        self.assertIn("no snapshot #9", p.stderr)
        self.assertIn("0001", p.stdout)          # lists what IS available

    # ------------------------------------------------------------------ gc

    def test_gc_prunes_old_copies(self):
        import hashlib
        import time
        proj_dir = self.a["claude"] / "projects" / PROJ
        hdir = proj_dir / "aaa" / "history"
        hdir.mkdir(parents=True)
        rdir = proj_dir / "revert"
        rdir.mkdir()
        base = time.time() - 10_000
        for i in range(12):                      # oldest first
            f = hdir / f"{i + 1:04d}-{hashlib.md5(f'h{i}'.encode()).hexdigest()[:8]}.jsonl"
            f.write_text(f"hist {i}\n", encoding="utf-8")
            os.utime(f, (base + i * 10, base + i * 10))
        for i in (1, 2):                         # revert copies, older still
            f = rdir / f"aaa.revert-2026010{i}-000000.jsonl"
            f.write_text(f"revert {i}\n", encoding="utf-8")
            os.utime(f, (base - i * 10, base - i * 10))
        self.local_file(self.a, "aaa").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        p = run_sessium(self.env(self.a), "gc", "--keep", "2")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("pruned 12 file(s)", p.stdout)
        remaining = sorted(hdir.glob("*.jsonl")) + sorted(rdir.glob("*.jsonl"))
        self.assertEqual(len(remaining), 2)      # the two NEWEST history files
        for f in remaining:
            self.assertTrue(f.stem.startswith(("0011", "0012")), f.stem)
        self.assertTrue(self.local_file(self.a, "aaa").is_file())  # canonical safe

    def test_gc_dry_run_touches_nothing(self):
        import hashlib
        hdir = self.a["claude"] / "projects" / PROJ / "aaa" / "history"
        hdir.mkdir(parents=True)
        for i in range(5):
            f = hdir / f"{i + 1:04d}-{hashlib.md5(f'h{i}'.encode()).hexdigest()[:8]}.jsonl"
            f.write_text(f"hist {i}\n", encoding="utf-8")
        p = run_sessium(self.env(self.a), "gc", "--keep", "2", "--dry-run")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.count("would prune"), 3)
        self.assertIn("dry-run: 3 file(s) would be pruned", p.stdout)
        self.assertEqual(len(list(hdir.glob("*.jsonl"))), 5)

    def test_gc_nothing_to_prune(self):
        p = run_sessium(self.env(self.a), "gc")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("nothing to prune", p.stdout)

    # ------------------------------------------------- --only fast lane

    def test_only_memory_syncs_both_ways_without_ledger(self):
        mem_dir = self.a["claude"] / "projects" / PROJ / "memory"
        mem_dir.mkdir(parents=True)
        (mem_dir / "MEMORY.md").write_text("A note\n", encoding="utf-8")
        p = run_sessium(self.env(self.a), "sync", "--only", "memory")
        self.assertEqual(p.returncode, 0, p.stderr)
        drive_mem = self.drive / "backup" / "projects" / PROJ / "memory" / "MEMORY.md"
        self.assertTrue(drive_mem.is_file())
        self.assertEqual(drive_mem.read_text(encoding="utf-8"), "A note\n")
        self.assertFalse(self.a["state"].exists())   # fast lane: no ledger
        # a newer Drive-side note flows back down
        (drive_mem).write_text("B note\n", encoding="utf-8")
        future = time.time() + 1000
        os.utime(drive_mem, (future, future))
        p = run_sessium(self.env(self.a), "sync", "--only", "memory")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual((mem_dir / "MEMORY.md").read_text(encoding="utf-8"),
                         "B note\n")

    def test_only_skills_syncs_both_ways(self):
        skill_dir = self.a["claude"] / "skills" / "my-skill"
        skill_dir.mkdir(parents=True)
        (skill_dir / "SKILL.md").write_text("skill body\n", encoding="utf-8")
        p = run_sessium(self.env(self.a), "sync", "--only", "skills")
        self.assertEqual(p.returncode, 0, p.stderr)
        drive_skill = self.drive / "backup" / "config" / "skills" / "my-skill" / "SKILL.md"
        self.assertTrue(drive_skill.is_file())
        # newer Drive-side skill flows back down
        drive_skill.write_text("skill v2\n", encoding="utf-8")
        future = time.time() + 1000
        os.utime(drive_skill, (future, future))
        p = run_sessium(self.env(self.a), "sync", "--only", "skills")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual((skill_dir / "SKILL.md").read_text(encoding="utf-8"),
                         "skill v2\n")

    def test_only_dry_run_touches_nothing(self):
        mem_dir = self.a["claude"] / "projects" / PROJ / "memory"
        mem_dir.mkdir(parents=True)
        (mem_dir / "MEMORY.md").write_text("A note\n", encoding="utf-8")
        p = run_sessium(self.env(self.a), "sync", "--only", "memory", "--dry-run")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("would two-way sync", p.stdout)
        self.assertFalse(
            (self.drive / "backup" / "projects" / PROJ / "memory").exists())

    def test_only_memory_never_touches_sessions(self):
        # the fast lane must not classify/transfer sessions
        self.local_file(self.a, "aaa").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        mem_dir = self.a["claude"] / "projects" / PROJ / "memory"
        mem_dir.mkdir(parents=True)
        (mem_dir / "MEMORY.md").write_text("A note\n", encoding="utf-8")
        p = run_sessium(self.env(self.a), "sync", "--only", "memory")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertFalse(self.drive_file("aaa").exists())   # session not pushed

    # ------------------------------------------------- diff --messages

    def test_diff_messages_flag(self):
        self._baseline_conflict()
        extra = "\n".join([
            json.dumps({"type": "user", "message": {"content": "what next"}}),
            json.dumps({"type": "assistant", "message": {"content": "done"}}),
        ]) + "\n"
        self.local_file(self.a, "aaa").write_text(
            SESSION_WITH_TITLE + extra, encoding="utf-8")
        p = run_sessium(self.env(self.a), "diff", "aaa", "--messages")
        self.assertEqual(p.returncode, 0, p.stderr)
        # transcript_messages skips meta + wrappers: 2 common msgs
        self.assertIn("common prefix: 2 message(s)", p.stdout)
        self.assertIn("local adds 2", p.stdout)
        self.assertIn("remote adds 0", p.stdout)
        self.assertIn("+ user", p.stdout)
        self.assertIn("+ assistant", p.stdout)
        p = run_sessium(self.env(self.a), "diff", "aaa", "--messages", "--json")
        self.assertEqual(p.returncode, 0, p.stderr)
        doc = json.loads(p.stdout)
        self.assertEqual(doc["preview"]["common"], 2)
        self.assertEqual(len(doc["preview"]["local_added"]), 2)
        self.assertEqual(doc["preview"]["remote_added"], [])
        self.assertEqual(doc["preview"]["local_added"][0], ["user", "what next"])


# ------------------------------------------------- batch 5: schedule/hook/crypt

class Batch5Tests(SyncBase):
    """schedule (systemd timer), hook (Stop hook), setup --encrypted (crypt)."""

    def test_push_quiet_silences_chatter(self):
        self.local_file(self.a, "aaa").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        p = run_sessium(self.env(self.a), "push", "--quiet")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, "")
        self.assertTrue(self.drive_file("aaa").is_file())
        # errors/warnings stay loud even when quiet
        self.local_file(self.a, "aaa").write_text("changed locally\n", encoding="utf-8")
        self.drive_file("aaa").write_text("changed remotely\n", encoding="utf-8")
        future = time.time() + 1000
        os.utime(self.drive_file("aaa"), (future, future))
        # stale the ledger record so both sides look changed → conflict
        entry = self.ledger(self.a)["sessions"][f"{PROJ}/aaa"]
        entry["local_md5"] = "stale"
        entry["remote_md5"] = "stale"
        self.a["state"].write_text(json.dumps(self.ledger(self.a)), encoding="utf-8")
        p = run_sessium(self.env(self.a), "push", "--quiet")
        self.assertEqual(p.returncode, 0)
        self.assertEqual(p.stdout, "")
        self.assertIn("CONFLICT", p.stderr)

    def _fake_systemctl(self) -> Path:
        bindir = self.tmp / "fake-bin"
        bindir.mkdir()
        stub = bindir / "systemctl"
        stub.write_text("#!/bin/bash\n"
                        'echo "$*" >> "$(dirname "$0")/calls.log"\n'
                        "exit 0\n", encoding="utf-8")
        stub.chmod(0o755)
        return bindir

    def _sched_env(self, bindir: Path) -> dict:
        env = self.env(self.a)
        env["SESSIUM_SYSTEMD_DIR"] = str(self.tmp / "systemd")
        env["PATH"] = f"{bindir}:{env['PATH']}"
        return env

    def test_schedule_print_touches_nothing(self):
        p = run_sessium(self.env(self.a), "schedule", "--print")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("ExecStart=", p.stdout)
        self.assertIn("sessium sync", p.stdout)
        self.assertIn("OnUnitActiveSec=30min", p.stdout)
        self.assertIn("enable --now sessium.timer", p.stdout)
        self.assertFalse((self.tmp / "systemd").exists())

    def test_schedule_install_and_off(self):
        env = self._sched_env(self._fake_systemctl())
        p = run_sessium(env, "schedule", "--interval", "15")
        self.assertEqual(p.returncode, 0, p.stderr)
        sdir = self.tmp / "systemd"
        service = (sdir / "sessium.service").read_text(encoding="utf-8")
        timer = (sdir / "sessium.timer").read_text(encoding="utf-8")
        self.assertIn("ExecStart=", service)
        self.assertIn("sessium sync", service)
        self.assertIn("OnUnitActiveSec=15min", timer)
        self.assertIn("WantedBy=timers.target", timer)
        calls = (self.tmp / "fake-bin" / "calls.log").read_text(encoding="utf-8")
        self.assertIn("daemon-reload", calls)
        self.assertIn("enable --now sessium.timer", calls)
        # --off: disable, then the unit files are gone
        p = run_sessium(env, "schedule", "--off")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("schedule removed", p.stdout)
        self.assertFalse((sdir / "sessium.timer").exists())
        self.assertFalse((sdir / "sessium.service").exists())
        calls = (self.tmp / "fake-bin" / "calls.log").read_text(encoding="utf-8")
        self.assertIn("disable --now sessium.timer", calls)

    def _settings(self) -> Path:
        return self.a["claude"] / "settings.json"

    def test_hook_install_idempotent_and_off(self):
        self._settings().write_text(json.dumps({
            "hooks": {"Stop": [{"matcher": "",
                                "hooks": [{"type": "command", "command": "echo unrelated"}]}]},
        }), encoding="utf-8")
        p = run_sessium(self.env(self.a), "hook")
        self.assertEqual(p.returncode, 0, p.stderr)
        data = json.loads(self._settings().read_text(encoding="utf-8"))
        stop = data["hooks"]["Stop"]
        self.assertEqual(len(stop), 2)
        sessium_hooks = [e for e in stop if "sessium push" in json.dumps(e)]
        self.assertEqual(len(sessium_hooks), 1)
        self.assertIn("push --quiet", sessium_hooks[0]["hooks"][0]["command"])
        # idempotent: a second install must not duplicate
        self.assertEqual(run_sessium(self.env(self.a), "hook").returncode, 0)
        data = json.loads(self._settings().read_text(encoding="utf-8"))
        self.assertEqual(len(data["hooks"]["Stop"]), 2)
        # --off: only the sessium entry goes
        p = run_sessium(self.env(self.a), "hook", "--off")
        self.assertEqual(p.returncode, 0, p.stderr)
        data = json.loads(self._settings().read_text(encoding="utf-8"))
        stop = data["hooks"]["Stop"]
        self.assertEqual(len(stop), 1)
        self.assertEqual(stop[0]["hooks"][0]["command"], "echo unrelated")

    def test_hook_off_leaves_empty_settings_clean(self):
        p = run_sessium(self.env(self.a), "hook")
        self.assertEqual(p.returncode, 0, p.stderr)
        p = run_sessium(self.env(self.a), "hook", "--off")
        self.assertEqual(p.returncode, 0, p.stderr)
        data = json.loads(self._settings().read_text(encoding="utf-8"))
        self.assertEqual(data, {})          # no hooks key left behind

    def test_hook_print_touches_nothing(self):
        p = run_sessium(self.env(self.a), "hook", "--print")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("sessium push --quiet", p.stdout)
        self.assertFalse(self._settings().exists())

    def test_setup_encrypted_switches_config(self):
        cfg_path = self.tmp / "config.json"
        cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
        cfg["seeker_url"] = "http://seeker.example"
        cfg_path.write_text(json.dumps(cfg), encoding="utf-8")
        p = run_sessium(self.env(self.a), "setup", "--encrypted")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("SAVE THIS PASSWORD", p.stdout)
        self.assertIn("sessium-crypt", p.stdout)
        # the crypt remote was created over the plain one, password logged
        log = (self.drive / "rclone-config.log").read_text(encoding="utf-8")
        self.assertRegex(log,
                         r"sessium-crypt crypt remote=fake:backup password=\S+")
        # sessium now points at the crypt remote; seeker_url survived
        new_cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
        self.assertEqual(new_cfg["rclone_remote"], "sessium-crypt")
        self.assertEqual(new_cfg["drive_folder"], "")
        self.assertEqual(new_cfg["seeker_url"], "http://seeker.example")


# ------------------------------------------------- batch 6: export / onboard

class Batch6Tests(SyncBase):
    """export (md/html + viewer index) and onboard (setup checklist)."""

    def _write_two(self):
        self.local_file(self.a, "aaa").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        self.local_file(self.a, "bbb").write_text(SESSION_ONLY_COMMANDS, encoding="utf-8")

    def test_export_markdown_single(self):
        self._write_two()
        out = self.tmp / "exp"
        p = run_sessium(self.env(self.a), "export", "aaa", "--out", str(out))
        self.assertEqual(p.returncode, 0, p.stderr)
        md = (out / "aaa.md").read_text(encoding="utf-8")
        self.assertIn("# hey, build me a spaceship", md)
        self.assertIn("## user", md)
        self.assertIn("## assistant", md)
        self.assertIn(f"- project: `{PROJ}`", md)
        self.assertFalse((out / "bbb.md").exists())     # single only

    def test_export_all_markdown(self):
        self._write_two()
        out = self.tmp / "exp"
        p = run_sessium(self.env(self.a), "export", "--all", "--out", str(out))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("exported 2 session(s)", p.stdout)
        self.assertTrue((out / "aaa.md").is_file())
        self.assertTrue((out / "bbb.md").is_file())

    def test_export_html_viewer(self):
        self._write_two()
        out = self.tmp / "exp"
        p = run_sessium(self.env(self.a), "export", "--all", "--html",
                        "--out", str(out))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("(+ index.html)", p.stdout)
        page = (out / "aaa.html").read_text(encoding="utf-8")
        self.assertIn("class='msg user'", page)
        self.assertIn("hey, build me a spaceship", page)
        index = (out / "index.html").read_text(encoding="utf-8")
        self.assertIn("href='aaa.html'", index)
        self.assertIn("href='bbb.html'", index)

    def test_export_requires_session_or_all(self):
        p = run_sessium(self.env(self.a), "export")
        self.assertEqual(p.returncode, 1)
        self.assertIn("--all", p.stderr)

    def test_export_remote_only_fails(self):
        self.drive_file("aaa").write_text(SESSION_WITH_TITLE, encoding="utf-8")
        p = run_sessium(self.env(self.a), "export", "aaa")
        self.assertEqual(p.returncode, 1)
        self.assertIn("pull first", p.stderr)

    def test_onboard_fresh_machine(self):
        env = self.env(self.a)
        env["SESSIUM_SYSTEMD_DIR"] = str(self.tmp / "systemd")   # nothing installed
        p = run_sessium(env, "onboard")
        self.assertEqual(p.returncode, 0, p.stderr)
        report = p.stdout + p.stderr      # warns land on stderr
        for marker in ("rclone present", "encryption: off", "Drive reachable",
                       "no sessions found", "ledger: empty",
                       "sync timer: not installed", "Stop hook: not installed",
                       "suggested next steps"):
            self.assertIn(marker, report)

    def test_onboard_all_set(self):
        self._write_two()
        self.a["state"].write_text(json.dumps({
            "version": 1,
            "sessions": {f"{PROJ}/aaa": {"project": PROJ, "id": "aaa",
                                         "local_md5": "x", "remote_md5": "x",
                                         "last_synced": "2026-11-05T00:00:00Z"}},
        }), encoding="utf-8")
        sdir = self.tmp / "systemd"
        sdir.mkdir(parents=True)
        (sdir / "sessium.timer").write_text("[Timer]\n", encoding="utf-8")
        (self.a["claude"] / "settings.json").write_text(
            json.dumps({"hooks": {"Stop": [{"hooks": [
                {"type": "command", "command": "sessium push --quiet"}]}]}}),
            encoding="utf-8")
        cfg_path = self.tmp / "config.json"
        cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
        cfg["rclone_remote"] = "sessium-crypt"
        cfg["drive_folder"] = ""
        cfg_path.write_text(json.dumps(cfg), encoding="utf-8")
        env = self.env(self.a)
        env["SESSIUM_SYSTEMD_DIR"] = str(sdir)
        p = run_sessium(env, "onboard")
        self.assertEqual(p.returncode, 0, p.stderr)
        for marker in ("encryption: on", "ledger: 1 session(s)",
                       "sync timer: installed", "Stop hook: installed",
                       "all set"):
            self.assertIn(marker, p.stdout)
