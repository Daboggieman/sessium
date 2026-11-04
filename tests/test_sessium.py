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


def run_sessium(env: dict, *args: str):
    return subprocess.run(
        [sys.executable, str(SESSIUM), *args],
        capture_output=True, text=True, env=env, timeout=60,
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
        self.assertEqual(self.mod.parse_rclone_time("2026-11-03T22:50:00.123456789Z"),
                         "2026-11-03 22:50")
        # a +01:00 offset must survive parsing (converted to UTC), not be sliced off
        self.assertEqual(self.mod.parse_rclone_time("2026-11-03T23:50:00+01:00"),
                         "2026-11-03 22:50")
        self.assertEqual(self.mod.parse_rclone_time(""), "")
        self.assertEqual(self.mod.parse_rclone_time("garbage"), "garbage"[:16])

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
        self.fx.write_remote("aaa-same", SESSION_WITH_TITLE)      # in-sync
        self.fx.write_local("bbb-local", SESSION_ONLY_COMMANDS)   # local-only
        self.fx.write_remote("ccc-remote", SESSION_WITH_BLOCKS)   # remote-only
        self.fx.write_local("ddd-diverged", SESSION_WITH_TITLE)
        self.fx.write_remote("ddd-diverged", SESSION_ONLY_COMMANDS)  # diverged
        proc = run_sessium(self.fx.env(), "status")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        for state in ("in-sync: 1", "local-only: 1", "remote-only: 1", "DIVERGED: 1"):
            self.assertIn(state, proc.stdout)

    def test_status_remote_unreachable_stays_local(self):
        self.fx.write_local("aaa", SESSION_WITH_TITLE)
        env = self.fx.env()
        env["SESSIUM_RCLONE_BIN"] = "/bin/false"  # every rclone call fails
        proc = run_sessium(env, "status")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("local-only view", proc.stderr)
        self.assertIn("local-only: 1", proc.stdout)

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
