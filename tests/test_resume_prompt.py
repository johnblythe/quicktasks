#!/usr/bin/env python3
"""Headless resume with a prompt: `qt resume <id> --prompt "<text>" [--thread
<ts>]`. Continues a finished task's Claude session with no tty (the path a
Slack-thread reply drives), appends the result onto the task's prior
output, and mirrors the continuation into the hub as a new job so its
finish notice can be posted threaded under `--thread`.

Follows the two test styles already established in this suite:
- End-to-end subprocess tests (test_slack_guard.py's
  RunTaskSettingsEndToEndTests / test_hub_feed.py's HubFeedEndToEndTests)
  for the exact claude argv/settings shape and the hub job/RESULT.md/
  job.json content a real `qt resume ... --prompt ...` invocation produces.
- In-process module-import tests (test_run_task_resilience.py's pattern)
  for the refusal paths and the still-interactive no-prompt path, where a
  real claude subprocess or execvp would be wrong to actually run.
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
from unittest.mock import patch

REPO_ROOT = Path(__file__).resolve().parent.parent
QT_SCRIPT = REPO_ROOT / "qt"
HUB_REPO = REPO_ROOT.parent / "hub"
TMP_ROOT = REPO_ROOT / "tmp"


def _load_qt_module(name="qt_resume_prompt_under_test"):
    loader = importlib.machinery.SourceFileLoader(name, str(QT_SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def _write_exec(path, text):
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


# Captures its own argv and -- critically -- reads the --settings file's
# contents itself, since real cmd_resume_prompt() deletes that file in a
# `finally` the instant this process returns (same contract as
# FAKE_CLAUDE_ARGV in test_slack_guard.py).
FAKE_CLAUDE_ARGV = """\
#!/usr/bin/env python3
import json, os, sys
argv = sys.argv[1:]
settings_content = None
if "--settings" in argv:
    p = argv[argv.index("--settings") + 1]
    try:
        with open(p) as f:
            settings_content = f.read()
    except OSError:
        settings_content = None
log = os.environ.get("FAKE_CLAUDE_ARGV_LOG")
if log:
    with open(log, "w") as f:
        json.dump({"argv": argv, "settings_content": settings_content}, f)
sys.stdout.write(os.environ.get("FAKE_CLAUDE_JSON", "{}") + "\\n")
sys.exit(int(os.environ.get("FAKE_CLAUDE_RC", "0")))
"""

FAKE_NOTIFIER_SHIM = """\
#!/usr/bin/env python3
import sys
sys.exit(0)
"""

FAKE_NOTICE_PY = """\
#!/usr/bin/env python3
import os, sys
log = os.environ.get("FAKE_NOTICE_LOG")
if log:
    with open(log, "a") as f:
        f.write(repr(sys.argv[1:]) + "\\n")
sys.exit(0)
"""


def _base_task(tid, **overrides):
    task = {
        "id": tid,
        "prompt": "original prompt",
        "status": "done",
        "created": "2025-01-01T00:00:00",
        "started": "2025-01-01T00:00:00",
        "finished": "2025-01-01T00:00:05",
        "origin": "qt",
        "invoked_from": "/tmp",
        "run_cwd": "/tmp",
        "perm_mode": "acceptEdits",
        "model": None,
        "session_id": "sess-orig",
        "result": "original result",
        "cost_usd": 0.01,
    }
    task.update(overrides)
    return task


class ResumePromptEndToEndTests(unittest.TestCase):
    """Drives `qt resume <id> --prompt ...` as a real subprocess against a
    throwaway QT_DATA (and, for the hub-mirroring tests, a throwaway hub
    dir), with a fake claude on PATH that captures its own argv and the
    referenced --settings file's contents."""

    def setUp(self):
        TMP_ROOT.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=str(TMP_ROOT))
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.qt_data = root / "qtdata"
        (self.qt_data / "tasks").mkdir(parents=True)
        self.run_cwd = root / "cwd"
        self.run_cwd.mkdir()

        bin_dir = root / "bin"
        bin_dir.mkdir()
        _write_exec(bin_dir / "claude", FAKE_CLAUDE_ARGV)
        for name in ("osascript", "terminal-notifier"):
            _write_exec(bin_dir / name, FAKE_NOTIFIER_SHIM)
        self.assertNotIn("/T/", str(bin_dir))
        self.bin_dir = bin_dir
        self.argv_log = root / "argv.json"

    def _write_task(self, tid, **overrides):
        task = _base_task(tid, run_cwd=str(self.run_cwd), **overrides)
        (self.qt_data / "tasks" / f"{tid}.json").write_text(json.dumps(task))
        return task

    def _load_task(self, tid):
        return json.loads((self.qt_data / "tasks" / f"{tid}.json").read_text())

    def _run_qt(self, resume_args, hub_dir=None, extra_env=None):
        env = dict(os.environ)
        env["QT_DATA"] = str(self.qt_data)
        env["PATH"] = f"{self.bin_dir}:{env.get('PATH', '')}"
        env["FAKE_CLAUDE_ARGV_LOG"] = str(self.argv_log)
        env.setdefault("FAKE_CLAUDE_JSON",
                        json.dumps({"result": "continued fine", "session_id": "sess-new"}))
        env.setdefault("FAKE_CLAUDE_RC", "0")
        if hub_dir is not None:
            env["QT_HUB"] = str(hub_dir)
        else:
            env.pop("QT_HUB", None)
        env.pop("QT_PERMISSIONS", None)
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [sys.executable, str(QT_SCRIPT), "resume"] + resume_args,
            capture_output=True, text=True, env=env, timeout=30,
        )

    def test_argv_shape_and_settings_file_lifecycle(self):
        tid = "250101-000000-argv"
        self._write_task(tid)

        proc = self._run_qt([tid, "--prompt", "continue please"])
        self.assertEqual(proc.returncode, 0, proc.stderr)

        captured = json.loads(self.argv_log.read_text())
        argv = captured["argv"]
        self.assertIn("-p", argv)
        self.assertEqual(argv[argv.index("-p") + 1], "continue please")
        self.assertIn("--output-format", argv)
        self.assertEqual(argv[argv.index("--output-format") + 1], "json")
        self.assertIn("--resume", argv)
        self.assertEqual(argv[argv.index("--resume") + 1], "sess-orig")
        self.assertIn("--settings", argv)
        settings_path = argv[argv.index("--settings") + 1]

        # the guard hook existed while claude ran
        self.assertIsNotNone(captured["settings_content"], "settings file was gone during the run")
        settings = json.loads(captured["settings_content"])
        hook = settings["hooks"]["PreToolUse"][0]
        self.assertEqual(hook["matcher"], "mcp__.*[Ss]lack.*")
        self.assertIn("qt-guard.py", hook["hooks"][0]["command"])

        # ...and was removed once the run finished
        self.assertFalse(os.path.exists(settings_path), "settings file was not cleaned up")

    def test_task_record_gets_resumes_appended_output_and_status(self):
        tid = "250101-000000-record"
        self._write_task(tid)

        proc = self._run_qt([tid, "--prompt", "continue please"])
        self.assertEqual(proc.returncode, 0, proc.stderr)

        task = self._load_task(tid)
        self.assertEqual(task["status"], "done")
        self.assertEqual(task["session_id"], "sess-new")
        self.assertIn("original result", task["result"])
        self.assertIn("## Continuation", task["result"])
        self.assertIn("continue please", task["result"])
        self.assertIn("continued fine", task["result"])
        # previous output is kept, not overwritten
        self.assertTrue(task["result"].index("original result") < task["result"].index("continued fine"))

        self.assertEqual(len(task["resumes"]), 1)
        resume = task["resumes"][0]
        self.assertEqual(resume["prompt"], "continue please")
        self.assertEqual(resume["rc"], 0)
        self.assertIsNone(resume["thread"])
        self.assertIn("at", resume)

    def test_failed_continuation_status_and_resumes_entry(self):
        tid = "250101-000000-failed"
        self._write_task(tid)

        proc = self._run_qt(
            [tid, "--prompt", "break please"],
            extra_env={
                "FAKE_CLAUDE_JSON": json.dumps({"result": "it broke", "is_error": True,
                                                 "session_id": "sess-broke"}),
                "FAKE_CLAUDE_RC": "2",
            },
        )
        self.assertEqual(proc.returncode, 1)

        task = self._load_task(tid)
        self.assertEqual(task["status"], "failed")
        self.assertEqual(task["resumes"][0]["rc"], 2)
        self.assertIn("it broke", task["result"])

    def test_hub_mirrors_only_continuation_result_and_thread_ts(self):
        if not (HUB_REPO / "seed.py").is_file():
            self.skipTest(f"real hub repo not found at {HUB_REPO}")
        hub_dir = Path(self.tmp.name) / "hub"
        hub_dir.mkdir()
        for name in ("seed.py", "items_io.py"):
            source = HUB_REPO / name
            if source.is_file():
                (hub_dir / name).write_text(source.read_text())
        (hub_dir / "items.json").write_text(json.dumps({"items": []}))
        notice_path = hub_dir / "notice.py"
        notice_path.write_text(FAKE_NOTICE_PY)
        notice_path.chmod(notice_path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
        notice_log = Path(self.tmp.name) / "notice.log"

        tid = "250101-000000-hub"
        self._write_task(tid)

        proc = self._run_qt(
            [tid, "--prompt", "continue please", "--thread", "1234.5678"],
            hub_dir=hub_dir,
            extra_env={"FAKE_NOTICE_LOG": str(notice_log)},
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)

        item_id = f"qt-{tid}"
        jobdirs = list((hub_dir / "jobs").glob(f"{item_id}-*"))
        self.assertEqual(len(jobdirs), 1, f"expected one jobdir, got {jobdirs}")
        jobdir = jobdirs[0]

        job = json.loads((jobdir / "job.json").read_text())
        result_md = (jobdir / "output" / "RESULT.md").read_text()
        # only the continuation's own result -- not the accumulated
        # task["result"] with "original result" and the heading in it.
        self.assertEqual(result_md.strip(), "continued fine")
        self.assertNotIn("original result", result_md)
        self.assertNotIn("## Continuation", result_md)
        self.assertEqual(job["thread_ts"], "1234.5678")

        self.assertTrue(notice_log.is_file(), "notice.py was never invoked")
        notice_argv = notice_log.read_text().strip()
        self.assertIn(str(jobdir), notice_argv)
        self.assertIn("--thread", notice_argv)
        self.assertIn("1234.5678", notice_argv)

    def test_notice_receives_no_thread_flag_when_none_given(self):
        if not (HUB_REPO / "seed.py").is_file():
            self.skipTest(f"real hub repo not found at {HUB_REPO}")
        hub_dir = Path(self.tmp.name) / "hub"
        hub_dir.mkdir()
        for name in ("seed.py", "items_io.py"):
            source = HUB_REPO / name
            if source.is_file():
                (hub_dir / name).write_text(source.read_text())
        (hub_dir / "items.json").write_text(json.dumps({"items": []}))
        notice_path = hub_dir / "notice.py"
        notice_path.write_text(FAKE_NOTICE_PY)
        notice_path.chmod(notice_path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
        notice_log = Path(self.tmp.name) / "notice-nothread.log"

        tid = "250101-000000-nothread"
        self._write_task(tid)

        proc = self._run_qt(
            [tid, "--prompt", "continue please"],
            hub_dir=hub_dir,
            extra_env={"FAKE_NOTICE_LOG": str(notice_log)},
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(notice_log.is_file())
        notice_argv = notice_log.read_text().strip()
        self.assertNotIn("--thread", notice_argv)

    def test_hub_slug_resolves_to_the_original_task(self):
        tid = "260909-165637-do-a-deep"
        self._write_task(tid)
        hub_slug = f"qt-{tid}-20260909-210126"

        proc = self._run_qt([hub_slug, "--prompt", "continue please"])
        self.assertEqual(proc.returncode, 0, proc.stderr)

        task = self._load_task(tid)
        self.assertEqual(len(task["resumes"]), 1)
        # no stray task file got created under the hub-slug name
        self.assertFalse((self.qt_data / "tasks" / f"{hub_slug}.json").exists())

    def test_missing_session_id_refuses_with_nonzero_exit(self):
        tid = "250101-000000-nosession"
        self._write_task(tid, session_id=None)

        proc = self._run_qt([tid, "--prompt", "continue please"])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("no session id", proc.stderr)

        task = self._load_task(tid)
        self.assertEqual(task["status"], "done")  # untouched: refused before any run

    def test_currently_running_task_refuses_with_nonzero_exit(self):
        tid = "250101-000000-running"
        self._write_task(tid, status="running")

        proc = self._run_qt([tid, "--prompt", "continue please"])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("running", proc.stderr)

        # never touched claude at all
        self.assertFalse(self.argv_log.exists())

    def test_prompt_dash_reads_from_stdin(self):
        tid = "250101-000000-stdin"
        self._write_task(tid)

        env = dict(os.environ)
        env["QT_DATA"] = str(self.qt_data)
        env["PATH"] = f"{self.bin_dir}:{env.get('PATH', '')}"
        env["FAKE_CLAUDE_ARGV_LOG"] = str(self.argv_log)
        env["FAKE_CLAUDE_JSON"] = json.dumps({"result": "ok", "session_id": "sess-new"})
        env["FAKE_CLAUDE_RC"] = "0"
        env.pop("QT_HUB", None)
        proc = subprocess.run(
            [sys.executable, str(QT_SCRIPT), "resume", tid, "--prompt", "-"],
            input="text piped over stdin", capture_output=True, text=True, env=env, timeout=30,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        captured = json.loads(self.argv_log.read_text())
        argv = captured["argv"]
        self.assertEqual(argv[argv.index("-p") + 1], "text piped over stdin")


class ResumeNoPromptStillInteractiveTests(unittest.TestCase):
    """`qt resume <id>` with no --prompt must still take the exact
    interactive path it always has: os.execvp(claude, [claude, "--resume",
    sid]), never routed through the new headless machinery. Driven via
    module import with os.execvp monkeypatched (a real execvp never
    returns, which would hang the test)."""

    def setUp(self):
        self.qt = _load_qt_module("qt_resume_no_prompt_under_test")
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.qt.QT_DATA = str(root)
        self.qt.TASKS_DIR = os.path.join(self.qt.QT_DATA, "tasks")
        self.qt.LOGS_DIR = os.path.join(self.qt.QT_DATA, "logs")
        self.qt.WORKSPACE = os.path.join(self.qt.QT_DATA, "workspace")
        self.qt.TMP_DIR = os.path.join(self.qt.QT_DATA, "tmp")
        self.qt.CONFIG_PATH = os.path.join(self.qt.QT_DATA, "config.json")
        self.qt.bootstrap()

        self.tid = "250101-000000-interactive"
        task = _base_task(self.tid, run_cwd=self.qt.WORKSPACE)
        self.qt.save(task)

        self.qt.find_claude = lambda: "/usr/bin/fake-claude"
        self.execvp_calls = []

        def fake_execvp(cmd, argv):
            self.execvp_calls.append((cmd, argv))

        self.qt.os.execvp = fake_execvp

    def test_bare_resume_still_calls_execvp_with_resume_and_session_id(self):
        with patch.object(sys, "argv", ["qt", "resume", self.tid]):
            self.qt.main()
        self.assertEqual(len(self.execvp_calls), 1)
        cmd, argv = self.execvp_calls[0]
        self.assertEqual(cmd, "/usr/bin/fake-claude")
        self.assertEqual(argv, ["/usr/bin/fake-claude", "--resume", "sess-orig"])

        # the interactive path never touched the headless machinery: no
        # resumes[] entry, no status change.
        task = self.qt.load(self.tid)
        self.assertNotIn("resumes", task)
        self.assertEqual(task["status"], "done")


if __name__ == "__main__":
    unittest.main()
