#!/usr/bin/env python3
"""run_task() must never leave a task stuck at "running" just because its
data directory vanished mid-run (a fresh-install rehearsal renaming
~/.quicktasks while a quick-fire was in flight did exactly this: the Claude
process finished fine, then the log-append crashed with FileNotFoundError
and the task JSON was never updated past "running").

These are in-process unit tests against qt loaded as a module (same import
pattern HubMappingUnitTests in test_hub_feed.py uses), with subprocess.run
patched per-test rather than a real claude binary on PATH -- both failure
scenarios need a controlled, deterministic reproduction rather than a race
against a real subprocess. QT_DATA and every path derived from it are
pointed at a throwaway tmp dir before any of run_task()'s own directory
constants are touched; nothing here reads or writes ~/.quicktasks.
"""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

REPO_ROOT = Path(__file__).resolve().parent.parent
QT_SCRIPT = REPO_ROOT / "qt"


def _load_qt_module():
    """Import qt as a module (rather than running it) so run_task() can be
    called directly with its dependencies stubbed out."""
    loader = importlib.machinery.SourceFileLoader("qt_under_test_resilience", str(QT_SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class RunTaskResilienceTests(unittest.TestCase):
    def setUp(self):
        self.qt = _load_qt_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)

        # Every path constant run_task()/save()/bootstrap() touch is
        # re-derived from a throwaway root -- not just QT_DATA, since the
        # module already computed the real-QT_DATA-derived versions at
        # import time.
        self.qt.QT_DATA = str(root)
        self.qt.TASKS_DIR = os.path.join(self.qt.QT_DATA, "tasks")
        self.qt.LOGS_DIR = os.path.join(self.qt.QT_DATA, "logs")
        self.qt.WORKSPACE = os.path.join(self.qt.QT_DATA, "workspace")
        self.qt.TMP_DIR = os.path.join(self.qt.QT_DATA, "tmp")
        self.qt.CONFIG_PATH = os.path.join(self.qt.QT_DATA, "config.json")
        self.qt.bootstrap()

        # claude discovery, the Slack-guard settings render, desktop
        # notifications, and the hub feed are all out of scope for these
        # tests (each has its own coverage elsewhere) -- stub them so a
        # failure or a real side effect in any of them can't be mistaken
        # for a run_task() resilience regression.
        self.qt.find_claude = lambda: "/usr/bin/true"
        self.qt.render_slack_guard_settings = lambda tid: None
        self.qt.notify = lambda *a, **k: None
        self.qt.notify_blocked = lambda *a, **k: None
        self.feed_hub_calls = []
        self.qt._feed_hub = lambda task, rc=None: self.feed_hub_calls.append(
            (task["status"], rc)
        )

    def _make_task(self, prompt):
        tid = self.qt.new_id(prompt)
        task = {
            "id": tid,
            "prompt": prompt,
            "status": "queued",
            "created": self.qt.now(),
            "origin": "qt",
            "invoked_from": os.getcwd(),
            "run_cwd": self.qt.WORKSPACE,
            "perm_mode": "acceptEdits",
            "model": None,
            "session_id": None,
            "result": None,
            "cost_usd": None,
        }
        self.qt.save(task)
        return tid

    def test_logs_dir_missing_mid_run_ends_done_with_hub_feed_attempted(self):
        """The claude subprocess "finishes" by deleting LOGS_DIR right
        before returning -- standing in for ~/.quicktasks being renamed out
        from under a running task. run_task() must not raise, the task
        must end "done", and the hub feed must still have been attempted."""
        tid = self._make_task("a task whose logs dir vanishes mid-run")
        fake_result = json.dumps({"result": "fine", "session_id": "sess-x"}) + "\n"

        def fake_run(*args, **kwargs):
            shutil.rmtree(self.qt.LOGS_DIR, ignore_errors=True)
            return types.SimpleNamespace(returncode=0, stdout=fake_result, stderr="")

        with patch("subprocess.run", side_effect=fake_run):
            self.qt.run_task(tid)  # must not raise

        task = self.qt.load(tid)
        self.assertEqual(task["status"], "done")
        self.assertEqual(task["result"], "fine")

        # the log append survives the missing directory: it's recreated
        # rather than the write being silently lost forever.
        log_path = os.path.join(self.qt.LOGS_DIR, tid + ".log")
        self.assertTrue(os.path.isfile(log_path), "log dir was not recreated")
        self.assertIn("fine", Path(log_path).read_text())

        self.assertEqual(self.feed_hub_calls, [("done", 0)])

    def test_unexpected_exception_leaves_task_failed_never_running(self):
        """An unexpected exception raised while the claude process is
        launching (rather than the specific, already-handled
        subprocess.TimeoutExpired) must not leave the task at "running"
        forever: run_task() re-raises for the caller to see, but the task
        JSON is stamped "failed" with the exception text first."""
        tid = self._make_task("a task whose claude launch blows up")

        with patch("subprocess.run", side_effect=RuntimeError("simulated launch failure")):
            with self.assertRaises(RuntimeError):
                self.qt.run_task(tid)

        task = self.qt.load(tid)
        self.assertEqual(task["status"], "failed")
        self.assertIn("simulated launch failure", task["result"])
        self.assertIn("finished", task)
        # the failure happened before a terminal status existed, so the
        # hub was never fed a half-finished task.
        self.assertEqual(self.feed_hub_calls, [])


if __name__ == "__main__":
    unittest.main()
