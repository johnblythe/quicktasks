#!/usr/bin/env python3
"""`qt setup --defaults [--hub <dir>]`: the non-interactive path the hub's
one-command installer drives (no stdin prompts of any kind, unlike plain
`qt setup`, which is covered separately in test_resume_launch.py's
SetupDefaultModelTests).

End-to-end against the real `qt` script, subprocess-driven, with QT_DATA
pointed at a throwaway temp dir under this repo's own tmp/ so nothing
touches ~/.quicktasks.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
QT_SCRIPT = REPO_ROOT / "qt"
TMP_ROOT = REPO_ROOT / "tmp"


class SetupDefaultsTests(unittest.TestCase):
    def setUp(self):
        TMP_ROOT.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=str(TMP_ROOT))
        self.addCleanup(self.tmp.cleanup)
        self.qt_data = Path(self.tmp.name) / "qtdata"

    def _run(self, *args):
        env = dict(os.environ)
        env["QT_DATA"] = str(self.qt_data)
        env.pop("QT_HUB", None)
        return subprocess.run(
            [sys.executable, str(QT_SCRIPT), "setup", "--defaults", *args],
            capture_output=True, text=True, env=env, timeout=30,
        )

    def _config(self):
        with open(self.qt_data / "config.json") as f:
            return json.load(f)

    def _make_hub_dir(self, name="hub"):
        hub = Path(self.tmp.name) / name
        hub.mkdir()
        (hub / "serve.py").touch()
        return hub

    def test_defaults_with_hub_writes_expected_keys(self):
        hub = self._make_hub_dir()
        proc = self._run("--hub", str(hub))
        self.assertEqual(proc.returncode, 0, proc.stderr)

        cfg = self._config()
        self.assertEqual(cfg["permissions"], "acceptEdits")
        self.assertEqual(cfg["model"], "sonnet[1m]")
        self.assertEqual(cfg["hub_dir"], str(hub.resolve()))
        self.assertIn("terminal", cfg)
        # No prompt exists in this path to collect one, and the hub's own
        # guard.py governs Slack policy once a hub is configured -- it must
        # never end up set to some stale or guessed value.
        self.assertNotIn("slack_owner_id", cfg)

        self.assertIn("permissions: acceptEdits", proc.stdout)
        self.assertIn("model: sonnet[1m]", proc.stdout)
        self.assertIn(f"hub_dir: {hub.resolve()}", proc.stdout)
        self.assertIn("saved", proc.stdout)

    def test_rerun_is_idempotent_and_preserves_untouched_keys(self):
        hub = self._make_hub_dir()
        first = self._run("--hub", str(hub))
        self.assertEqual(first.returncode, 0, first.stderr)

        # Simulate a key --defaults never touches having been set some
        # other way (`qt trust`, manual edit, a prior interactive `qt
        # setup`) -- a rerun must not clobber it.
        cfg = self._config()
        cfg["trusted_dirs"] = ["/tmp/some-trusted-dir"]
        cfg["notifier"] = "terminal-notifier"
        with open(self.qt_data / "config.json", "w") as f:
            json.dump(cfg, f)

        second = self._run("--hub", str(hub))
        self.assertEqual(second.returncode, 0, second.stderr)

        cfg2 = self._config()
        self.assertEqual(cfg2["permissions"], "acceptEdits")
        self.assertEqual(cfg2["model"], "sonnet[1m]")
        self.assertEqual(cfg2["hub_dir"], str(hub.resolve()))
        self.assertEqual(cfg2["trusted_dirs"], ["/tmp/some-trusted-dir"])
        self.assertEqual(cfg2["notifier"], "terminal-notifier")

    def test_missing_serve_py_fails_clearly_and_writes_nothing(self):
        not_a_hub = Path(self.tmp.name) / "not-a-hub"
        not_a_hub.mkdir()

        proc = self._run("--hub", str(not_a_hub))
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("serve.py", proc.stderr)
        self.assertIn(str(not_a_hub.resolve()), proc.stderr)
        self.assertFalse((self.qt_data / "config.json").exists())

    def test_hub_dir_must_be_a_directory(self):
        not_a_dir = Path(self.tmp.name) / "nope"
        proc = self._run("--hub", str(not_a_dir))
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("not a directory", proc.stderr)
        self.assertFalse((self.qt_data / "config.json").exists())

    def test_defaults_without_hub_leaves_hub_mode_off_and_says_so(self):
        proc = self._run()
        self.assertEqual(proc.returncode, 0, proc.stderr)

        cfg = self._config()
        self.assertNotIn("hub_dir", cfg)
        self.assertNotIn("slack_owner_id", cfg)
        self.assertEqual(cfg["permissions"], "acceptEdits")
        self.assertEqual(cfg["model"], "sonnet[1m]")

        self.assertIn("hub_dir: off", proc.stdout)

    def test_hub_flag_without_a_value_errors(self):
        proc = self._run("--hub")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("--hub needs a directory", proc.stderr)


if __name__ == "__main__":
    unittest.main()
