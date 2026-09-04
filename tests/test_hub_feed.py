#!/usr/bin/env python3
"""Hub mode stage 1: finished quicktasks feed into The Pass's ledger.

End-to-end tests drive the real `qt` script as a subprocess against a
throwaway QT_DATA and a throwaway hub dir (a copy of the real hub repo's
seed.py plus a minimal items.json), with a fake `claude` binary on PATH
that prints canned --output-format json output. A couple of mapping rules
that are cheapest to check directly (timeout, and the item shape) are
covered at the unit level instead, per the hub repo's own test style of
importing the script as a module.
"""
import importlib.machinery
import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
QT_SCRIPT = REPO_ROOT / "qt"
HUB_REPO = REPO_ROOT.parent / "hub"
TMP_ROOT = REPO_ROOT / "tmp"

FAKE_CLAUDE = """\
#!/usr/bin/env python3
import os, sys, time
time.sleep(float(os.environ.get("FAKE_CLAUDE_SLEEP", "0")))
sys.stdout.write(os.environ.get("FAKE_CLAUDE_JSON", "{}") + "\\n")
sys.exit(int(os.environ.get("FAKE_CLAUDE_RC", "0")))
"""

# Every run_task() reaches notify(), which shells out to terminal-notifier
# or osascript to raise a real desktop notification. Both go through PATH
# lookup with no fixed path, so a no-op shim of each in the same fake-bin
# dir as fake claude intercepts them before they ever touch the real
# binary -- these tests should never pop a notification on the machine
# running them. Logs its argv (if told where) so a test can assert it was
# actually reached, rather than passing by accident because nothing calls
# notify() at all.
FAKE_NOTIFIER_SHIM = """\
#!/usr/bin/env python3
import os, sys
log = os.environ.get("FAKE_NOTIFY_LOG")
if log:
    with open(log, "a") as f:
        f.write(repr(sys.argv[1:]) + "\\n")
sys.exit(0)
"""


def _load_qt_module():
    """Import qt as a module (rather than running it) for the pure helper
    functions, following the same pattern the hub repo's own tests use for
    serve.py/reconcile.py."""
    loader = importlib.machinery.SourceFileLoader("qt_under_test", str(QT_SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class HubFeedEndToEndTests(unittest.TestCase):
    """Drives `qt` as a real subprocess end to end for the three statuses
    that must show up correctly in the Pass ledger: done, failed, blocked."""

    def setUp(self):
        if not (HUB_REPO / "seed.py").is_file():
            self.skipTest(f"real hub repo not found at {HUB_REPO}")
        TMP_ROOT.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=str(TMP_ROOT))
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)

        self.qt_data = root / "qtdata"
        self.hub_dir = root / "hub"
        (self.hub_dir).mkdir()
        # seed.py plus the local modules it imports. items_io arrived when the
        # hub moved items.json behind a cross-process lock and an atomic
        # write; without it seed.py dies at import and the feed silently seeds
        # nothing, which reads here as "the item never landed".
        for name in ("seed.py", "items_io.py"):
            source = HUB_REPO / name
            if source.is_file():
                (self.hub_dir / name).write_text(source.read_text())
        (self.hub_dir / "items.json").write_text(json.dumps({"items": []}))

        # A fake `claude` on PATH. Its resolved path must not contain "/T/"
        # or qt's find_claude() will reject it as a session-shim path and
        # fall through to a real install instead (macOS's default tempdir
        # is .../T/..., which is exactly why this lives under the repo's
        # own tmp/ rather than tempfile's default location).
        bin_dir = root / "bin"
        bin_dir.mkdir()
        claude_path = bin_dir / "claude"
        claude_path.write_text(FAKE_CLAUDE)
        claude_path.chmod(claude_path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
        self.assertNotIn("/T/", str(claude_path))
        self.bin_dir = bin_dir

        # No-op osascript + terminal-notifier: notify() must never reach the
        # real ones, so these tests don't pop a notification on whatever
        # machine runs them.
        for name in ("osascript", "terminal-notifier"):
            shim = bin_dir / name
            shim.write_text(FAKE_NOTIFIER_SHIM)
            shim.chmod(shim.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
        self.notify_log = root / "notify.log"

    def _run_qt(self, prompt, fake_json, fake_rc=0, extra_env=None):
        env = dict(os.environ)
        env["QT_DATA"] = str(self.qt_data)
        env["QT_HUB"] = str(self.hub_dir)
        env["PATH"] = f"{self.bin_dir}:{env.get('PATH', '')}"
        env["FAKE_NOTIFY_LOG"] = str(self.notify_log)
        env["FAKE_CLAUDE_JSON"] = json.dumps(fake_json)
        env["FAKE_CLAUDE_RC"] = str(fake_rc)
        env.pop("QT_PERMISSIONS", None)
        if extra_env:
            env.update(extra_env)
        proc = subprocess.run(
            [sys.executable, str(QT_SCRIPT), "-w", prompt],
            capture_output=True, text=True, env=env, timeout=30,
        )
        return proc

    def _the_task(self):
        files = list((self.qt_data / "tasks").glob("*.json"))
        self.assertEqual(len(files), 1, f"expected exactly one task, got {files}")
        return json.loads(files[0].read_text())

    def _the_item(self, item_id):
        items = json.loads((self.hub_dir / "items.json").read_text())["items"]
        matches = [it for it in items if it["id"] == item_id]
        self.assertEqual(len(matches), 1, f"expected one item {item_id}, got {items}")
        return matches[0]

    def _the_job(self, item_id):
        jobdirs = list((self.hub_dir / "jobs").glob(f"{item_id}-*"))
        self.assertEqual(len(jobdirs), 1, f"expected one jobdir for {item_id}, got {jobdirs}")
        jobdir = jobdirs[0]
        job = json.loads((jobdir / "job.json").read_text())
        result_md = (jobdir / "output" / "RESULT.md").read_text()
        return job, result_md

    def test_done_task_feeds_hub(self):
        prompt = "a" * 80  # long enough to exercise title truncation
        proc = self._run_qt(prompt, {
            "result": "All done, nothing else needed.",
            "session_id": "sess-done",
            "total_cost_usd": 0.02,
        })
        self.assertEqual(proc.returncode, 0, proc.stderr)

        task = self._the_task()
        self.assertEqual(task["status"], "done")
        item_id = f"qt-{task['id']}"

        item = self._the_item(item_id)
        self.assertEqual(item["quote"], prompt)
        self.assertEqual(item["title"], prompt[:59] + "…")
        self.assertEqual(item["source"], "qt")
        self.assertEqual(item["state"], "today")
        self.assertNotIn("prompt", item)  # fire false: no prompt key at all

        job, result_md = self._the_job(item_id)
        self.assertEqual(job["item_id"], item_id)
        self.assertEqual(job["status"], "done")
        self.assertEqual(job["rc"], 0)
        self.assertEqual(job["session_id"], "sess-done")
        self.assertIn("started", job)
        self.assertIn("finished", job)
        self.assertEqual(result_md.strip(), "All done, nothing else needed.")

        # notify() really did fire, and hit the shim rather than the real
        # osascript/terminal-notifier: proof the notification-suppression
        # fixture is doing something, not just silently unneeded.
        self.assertTrue(self.notify_log.is_file(), "notify() never reached the fake osascript shim")

    def test_failed_task_feeds_hub(self):
        prompt = "do something that breaks"
        proc = self._run_qt(prompt, {
            "result": "Something went wrong internally.",
            "is_error": True,
            "session_id": "sess-failed",
        }, fake_rc=2)
        self.assertEqual(proc.returncode, 1)

        task = self._the_task()
        self.assertEqual(task["status"], "failed")
        item_id = f"qt-{task['id']}"

        item = self._the_item(item_id)
        self.assertNotIn("prompt", item)

        job, result_md = self._the_job(item_id)
        self.assertEqual(job["status"], "failed")
        self.assertEqual(job["rc"], 2)
        self.assertEqual(job["error"], "Something went wrong internally.")
        self.assertEqual(result_md.strip(), "Something went wrong internally.")

    def test_blocked_task_feeds_hub(self):
        prompt = "do something that needs a denied tool"
        proc = self._run_qt(prompt, {
            "result": "",
            "session_id": "sess-blocked",
            "permission_denials": [
                {"tool_name": "Bash", "tool_input": {"command": "rm -rf /"}},
            ],
        })
        self.assertEqual(proc.returncode, 1)  # queue() exits 1 for anything but "done"

        task = self._the_task()
        self.assertEqual(task["status"], "blocked")
        item_id = f"qt-{task['id']}"

        job, result_md = self._the_job(item_id)
        self.assertEqual(job["status"], "blocked")  # the hub understands blocked directly
        resume_hint = f"qt resume {task['id']}"
        self.assertEqual(job["error"], f"blocked: 1 permission denials; resume: {resume_hint}")
        self.assertEqual(job["denials"], [
            {"tool_name": "Bash", "tool_input": {"command": "rm -rf /"}},
        ])
        self.assertIn("Blocked on Bash.", result_md)
        self.assertIn(resume_hint, result_md)

    def test_hub_off_by_default_is_a_no_op(self):
        """QT_HUB unset must be exactly today's behavior: no hub dir is
        even touched, let alone written to."""
        env_no_hub = dict(os.environ)
        env_no_hub["QT_DATA"] = str(self.qt_data)
        env_no_hub.pop("QT_HUB", None)
        env_no_hub["PATH"] = f"{self.bin_dir}:{env_no_hub.get('PATH', '')}"
        env_no_hub["FAKE_CLAUDE_JSON"] = json.dumps({"result": "fine", "session_id": "s"})
        env_no_hub["FAKE_CLAUDE_RC"] = "0"
        env_no_hub["FAKE_NOTIFY_LOG"] = str(self.notify_log)
        env_no_hub.pop("QT_PERMISSIONS", None)

        proc = subprocess.run(
            [sys.executable, str(QT_SCRIPT), "-w", "a task with no hub configured"],
            capture_output=True, text=True, env=env_no_hub, timeout=30,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        task = self._the_task()
        self.assertEqual(task["status"], "done")
        self.assertFalse((self.hub_dir / "jobs").exists())
        items = json.loads((self.hub_dir / "items.json").read_text())["items"]
        self.assertEqual(items, [])


class HubMappingUnitTests(unittest.TestCase):
    """Cheaper to check directly than to force through a real timed-out
    subprocess: the timeout status mapping, and the item's shape."""

    def setUp(self):
        self.qt = _load_qt_module()

    def test_timeout_maps_to_failed_with_timeout_error_and_no_rc(self):
        task = {
            "id": "250101-000000-test",
            "prompt": "a task that hangs",
            "status": "timeout",
            "result": "timed out after 30s",
            "started": "2025-01-01T00:00:00",
            "finished": "2025-01-01T00:00:30",
            "session_id": None,
        }
        job, body = self.qt._hub_job_record(task, "qt-250101-000000-test", rc=None)
        self.assertEqual(job["status"], "failed")
        self.assertEqual(job["error"], "timeout")
        self.assertNotIn("rc", job)  # rc is only set "where known"
        self.assertIn("qt resume 250101-000000-test", body)

    def test_hub_item_has_no_prompt_key(self):
        task = {
            "id": "250101-000000-test",
            "prompt": "short prompt",
            "created": "2025-01-01T00:00:00",
        }
        item = self.qt._hub_item(task)
        self.assertEqual(item["id"], "qt-250101-000000-test")
        self.assertEqual(item["quote"], "short prompt")
        self.assertEqual(item["title"], "short prompt")
        self.assertNotIn("prompt", item)

    def test_hub_title_truncates_around_60_chars(self):
        long_prompt = "x" * 100
        title = self.qt._hub_title(long_prompt)
        self.assertEqual(len(title), 60)
        self.assertTrue(title.endswith("…"))


if __name__ == "__main__":
    unittest.main()
