#!/usr/bin/env python3
"""qt stop / qt retry / stopped status / qt open -> ask URL.

Every test runs the real `qt` script as a subprocess against a throwaway
QT_DATA with a fake `claude` (and fake `open` / notifier shims) first on
PATH. Nothing here reads or writes ~/.quicktasks, the notify inbox, or any
live hub, and no real claude process is ever started. The hub-record tests
load qt as a module and write only into a tmp dir.
"""
import importlib.machinery
import importlib.util
import json
import os
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

REPO_ROOT = Path(__file__).resolve().parent.parent
QT_SCRIPT = REPO_ROOT / "qt"
TMP_ROOT = REPO_ROOT / "tmp"

# Fake claude: with FAKE_CLAUDE_PIDFILE set it spawns a long-lived child,
# records "<own pid> <child pid>", then sleeps like a run in flight. Without
# it, it just prints canned --output-format json. Argv is logged when
# FAKE_CLAUDE_ARGV is set so a test can see what a run was given.
FAKE_CLAUDE = """#!/usr/bin/env python3
import json, os, subprocess, sys, time
argv_log = os.environ.get("FAKE_CLAUDE_ARGV")
if argv_log:
    with open(argv_log, "a") as f:
        f.write(json.dumps(sys.argv[1:]) + "\\n")
pidfile = os.environ.get("FAKE_CLAUDE_PIDFILE")
if pidfile:
    child = subprocess.Popen(["sleep", "300"])
    with open(pidfile, "w") as f:
        f.write(f"{os.getpid()} {child.pid}")
    time.sleep(300)
sys.stdout.write(os.environ.get("FAKE_CLAUDE_JSON", "{}") + "\\n")
sys.exit(0)
"""

# Stand-in for osascript / terminal-notifier / open. `open` logs its argv and
# exits FAKE_OPEN_RC; the others do nothing.
NOOP_SHIM = """#!/usr/bin/env python3
import os, sys
name = os.path.basename(sys.argv[0])
if name == "open":
    log = os.environ.get("FAKE_SHIM_LOG_OPEN")
    if log:
        with open(log, "a") as f:
            f.write(repr(sys.argv[1:]) + "\\n")
    sys.exit(int(os.environ.get("FAKE_OPEN_RC", "0")))
sys.exit(0)
"""


def _load_qt_module(name="qt_under_test_moves"):
    loader = importlib.machinery.SourceFileLoader(name, str(QT_SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def _wait_for(pred, timeout=20.0, step=0.05):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        v = pred()
        if v:
            return v
        time.sleep(step)
    return None


def _alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    st = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)],
                        capture_output=True, text=True).stdout.strip()
    return bool(st) and not st.startswith("Z")


class QtMovesBase(unittest.TestCase):
    def setUp(self):
        TMP_ROOT.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=str(TMP_ROOT))
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.qt_data = root / "qtdata"
        self.bin_dir = root / "bin"
        self.bin_dir.mkdir()
        # find_claude() rejects any path containing /T/ (macOS tempdir).
        claude = self.bin_dir / "claude"
        claude.write_text(FAKE_CLAUDE)
        claude.chmod(claude.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
        self.assertNotIn("/T/", str(claude))
        shim_src = NOOP_SHIM
        for name in ("osascript", "terminal-notifier", "open"):
            shim = self.bin_dir / name
            shim.write_text(shim_src)
            shim.chmod(shim.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
        self.open_log = root / "open.log"
        self.pidfile = root / "pids"
        self.argv_log = root / "claude-argv.log"
        self.env = dict(os.environ)
        self.env.update({
            "QT_DATA": str(self.qt_data),
            "PATH": f"{self.bin_dir}:{os.environ.get('PATH', '')}",
            "QT_NOTIFY_INBOX": "0",
            "QT_LABEL_REFINE": "0",
            "FAKE_SHIM_LOG_OPEN": str(self.open_log),
            "FAKE_CLAUDE_ARGV": str(self.argv_log),
        })
        for k in ("QT_HUB", "QT_PERMISSIONS", "QT_ORIGIN", "QT_PASS_URL", "QT_TIMEOUT"):
            self.env.pop(k, None)
        self.addCleanup(self._reap)

    def _reap(self):
        """Never leave a fake sleeper behind, whatever the test did."""
        if self.pidfile.is_file():
            for tok in self.pidfile.read_text().split():
                try:
                    os.kill(int(tok), signal.SIGKILL)
                except (ProcessLookupError, ValueError):
                    pass
        tdir = self.qt_data / "tasks"
        if tdir.is_dir():
            for f in tdir.glob("*.json"):
                try:
                    pid = json.loads(f.read_text()).get("pid")
                    if isinstance(pid, int) and pid > 1:
                        os.killpg(pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError, ValueError, OSError):
                    pass

    # -- helpers --
    def qt(self, *args, env=None, stdin=None):
        e = dict(self.env)
        e.update(env or {})
        return subprocess.run([sys.executable, str(QT_SCRIPT), *args],
                              capture_output=True, text=True, env=e,
                              input=stdin, timeout=60)

    def task(self):
        files = list((self.qt_data / "tasks").glob("*.json"))
        self.assertEqual(len(files), 1, files)
        return json.loads(files[0].read_text())

    def tid(self):
        return self.task()["id"]

    def start_sleeper(self, prompt="check the vendor renewal"):
        """Queue a task whose fake claude hangs; return (tid, claude pid, child pid)."""
        self.pidfile.unlink(missing_ok=True)
        r = self.qt(prompt, env={"FAKE_CLAUDE_PIDFILE": str(self.pidfile)})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(_wait_for(lambda: self.pidfile.is_file() and len(self.pidfile.read_text().split()) == 2),
                        "fake claude never started")
        claude_pid, child_pid = (int(x) for x in self.pidfile.read_text().split())
        t = self.task()
        self.assertEqual(t["status"], "running")
        return t["id"], claude_pid, child_pid

    def finish_task(self, prompt="do the thing", result="all done"):
        """Run a task to completion (foreground) with canned output."""
        r = self.qt("-w", prompt, env={"FAKE_CLAUDE_JSON": json.dumps(
            {"result": result, "session_id": "sess-1", "total_cost_usd": 0.01})})
        self.assertEqual(r.returncode, 0, r.stderr)
        return self.tid()


class TestStop(QtMovesBase):
    def test_stop_kills_claude_and_its_child(self):
        tid, claude_pid, child_pid = self.start_sleeper()
        t = self.task()
        self.assertIsInstance(t.get("pid"), int)
        self.assertTrue(_alive(claude_pid) and _alive(child_pid))

        r = self.qt("stop", tid)
        self.assertEqual(r.returncode, 0, r.stderr)

        self.assertTrue(_wait_for(lambda: not _alive(claude_pid)), "claude survived qt stop")
        self.assertTrue(_wait_for(lambda: not _alive(child_pid)), "claude's child survived qt stop")
        self.assertFalse(_alive(t["pid"]), "the _run process survived qt stop")
        t = self.task()
        self.assertEqual(t["status"], "stopped")
        self.assertEqual(t["result"], "Stopped by you")
        self.assertTrue(t.get("finished"))

    def test_stop_accepts_id_fragment(self):
        tid, claude_pid, _ = self.start_sleeper()
        r = self.qt("stop", tid[-12:])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(_wait_for(lambda: not _alive(claude_pid)))
        self.assertEqual(self.task()["status"], "stopped")

    def test_stop_with_a_stale_recycled_pid_never_signals_it(self):
        """After a crash nothing resets a stale `running` record, and macOS
        recycles pids fast -- `qt stop` on such a record must verify the
        pid still belongs to this task's runner before any signal goes
        out, or it can SIGKILL an innocent process's whole group. A bare
        `sleep` holding the recorded pid is not ours: it survives, the
        task is still marked stopped."""
        import subprocess as sp
        sleeper = sp.Popen(["sleep", "300"])
        self.addCleanup(lambda: _alive(sleeper.pid) and
                        sp.run(["kill", str(sleeper.pid)],
                               capture_output=True))
        tid = "261119-150000-stale-recycled"
        (self.qt_data / "tasks").mkdir(parents=True, exist_ok=True)
        (self.qt_data / "tasks" / f"{tid}.json").write_text(json.dumps({
            "id": tid, "prompt": "a run that crashed long ago",
            "status": "running", "created": "2026-11-19T15:00:00",
            "origin": "qt", "invoked_from": "/tmp", "run_cwd": "/tmp",
            "perm_mode": "acceptEdits", "pid": sleeper.pid,
            "session_id": None, "result": None, "cost_usd": None}))
        r = self.qt("stop", tid)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("stale record", r.stdout)
        self.assertTrue(_alive(sleeper.pid),
                        "qt stop signaled a pid that was never this task's")
        t = self.task()
        self.assertEqual(t["status"], "stopped")
        self.assertEqual(t["result"], "Stopped by you")

    def test_stop_unknown_id_exits_1(self):
        (self.qt_data / "tasks").mkdir(parents=True)
        r = self.qt("stop", "nope-nothing")
        self.assertEqual(r.returncode, 1)

    def test_stop_lists_with_its_own_glyph(self):
        tid, claude_pid, _ = self.start_sleeper()
        self.qt("stop", tid)
        out = self.qt("list").stdout
        self.assertIn("■", out)
        self.assertNotIn("?", out.split(tid)[0])

    def test_stopped_run_does_not_ring_or_overwrite(self):
        """The killed run never reaches its finish path, so nothing
        flips the record back to done/failed afterwards."""
        tid, claude_pid, _ = self.start_sleeper()
        self.qt("stop", tid)
        self.assertTrue(_wait_for(lambda: not _alive(claude_pid)))
        time.sleep(0.5)
        self.assertEqual(self.task()["status"], "stopped")


class TestStopIdempotent(QtMovesBase):
    def test_stop_twice_is_exit_0(self):
        tid, claude_pid, _ = self.start_sleeper()
        self.assertEqual(self.qt("stop", tid).returncode, 0)
        r = self.qt("stop", tid)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("not running", r.stdout)
        self.assertEqual(self.task()["status"], "stopped")

    def test_stop_finished_task_says_not_running_and_leaves_it(self):
        tid = self.finish_task()
        before = self.task()
        r = self.qt("stop", tid)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("not running", r.stdout)
        self.assertEqual(self.task(), before)

    def test_stop_dead_runner_still_marks_stopped(self):
        """A run whose process vanished (crash) is stuck at running; stop clears it."""
        tid = self.finish_task()
        p = self.qt_data / "tasks" / f"{tid}.json"
        t = json.loads(p.read_text())
        t.update(status="running", pid=2 ** 22 + 12345)  # not a live pid
        p.write_text(json.dumps(t))
        r = self.qt("stop", tid)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.task()["status"], "stopped")


class TestRetrySameId(QtMovesBase):
    def test_retry_reruns_under_same_id(self):
        tid = self.finish_task(prompt="who owns the renewal", result="first answer")
        first = self.task()
        self.assertEqual(first["session_id"], "sess-1")

        r = self.qt("retry", tid, env={"FAKE_CLAUDE_JSON": json.dumps(
            {"result": "second answer", "session_id": "sess-2"})})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(tid, r.stdout)

        # still exactly one task record, same id, run again to completion
        self.assertTrue(_wait_for(lambda: self.task()["status"] == "done"
                                  and self.task()["result"] == "second answer"),
                        self.task())
        t = self.task()
        self.assertEqual(t["id"], tid)
        self.assertEqual(t["session_id"], "sess-2")
        self.assertEqual(t["prompt"], "who owns the renewal")
        self.assertEqual(len(t["attempts"]), 1)
        a = t["attempts"][0]
        self.assertEqual((a["kind"], a["n"], a["prompt"]), ("retry", 2, "who owns the renewal"))
        self.assertTrue(a["at"])

    def test_retry_resets_previous_outcome_before_it_runs(self):
        tid = self.finish_task()
        p = self.qt_data / "tasks" / f"{tid}.json"
        t = json.loads(p.read_text())
        t.update(status="blocked", denials=[{"tool_name": "Bash", "tool_input": {}}],
                 question="which one?", result="Blocked on Bash.")
        p.write_text(json.dumps(t))
        # a claude that hangs keeps the task observable mid-flight
        self.pidfile.unlink(missing_ok=True)
        r = self.qt("retry", tid, env={"FAKE_CLAUDE_PIDFILE": str(self.pidfile)})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(_wait_for(lambda: self.pidfile.is_file()))
        t = self.task()
        self.assertEqual(t["status"], "running")
        self.assertIsNone(t["session_id"])
        self.assertFalse(t["denials"])
        self.assertFalse(t.get("question"))
        self.assertNotEqual(t.get("result"), "Blocked on Bash.")

    def test_second_retry_numbers_attempts(self):
        tid = self.finish_task()
        for expect in (1, 2):
            self.assertEqual(self.qt("retry", tid, env={"FAKE_CLAUDE_JSON": json.dumps(
                {"result": f"r{expect}", "session_id": "s"})}).returncode, 0)
            self.assertTrue(_wait_for(lambda: self.task()["status"] == "done"
                                      and len(self.task()["attempts"]) == expect
                                      and self.task()["result"] == f"r{expect}"), self.task())
        self.assertEqual([a["n"] for a in self.task()["attempts"]], [2, 3])

    def test_retry_unknown_id_exits_1(self):
        (self.qt_data / "tasks").mkdir(parents=True)
        self.assertEqual(self.qt("retry", "nope-nothing").returncode, 1)

    def test_retry_after_stop(self):
        tid, claude_pid, _ = self.start_sleeper()
        self.qt("stop", tid)
        self.assertTrue(_wait_for(lambda: not _alive(claude_pid)))
        r = self.qt("retry", tid, env={"FAKE_CLAUDE_JSON": json.dumps(
            {"result": "worked this time", "session_id": "s9"})})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(_wait_for(lambda: self.task()["status"] == "done"), self.task())
        self.assertEqual(self.task()["result"], "worked this time")


class TestRetryWithPrompt(QtMovesBase):
    def test_retry_with_prompt_replaces_the_words(self):
        tid = self.finish_task(prompt="who owns the renewal")
        r = self.qt("retry", tid, "--prompt", "who owns the GitHub renewal, and when is it due",
                    env={"FAKE_CLAUDE_JSON": json.dumps({"result": "ok", "session_id": "s3"})})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(_wait_for(lambda: self.task()["status"] == "done"
                                  and len(self.task().get("attempts") or []) == 1), self.task())
        t = self.task()
        self.assertEqual(t["prompt"], "who owns the GitHub renewal, and when is it due")
        self.assertEqual(t["attempts"][0]["prompt"], t["prompt"])
        self.assertIn("GitHub", t["label"])
        # the run was actually given the new words
        argv = [json.loads(l) for l in self.argv_log.read_text().splitlines()]
        self.assertIn("who owns the GitHub renewal, and when is it due", argv[-1][argv[-1].index("-p") + 1])

    def test_retry_prompt_from_stdin(self):
        tid = self.finish_task(prompt="first words")
        r = self.qt("retry", tid, "--prompt", "-", stdin="words from stdin",
                    env={"FAKE_CLAUDE_JSON": json.dumps({"result": "ok", "session_id": "s4"})})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(_wait_for(lambda: self.task()["status"] == "done"
                                  and self.task().get("attempts")), self.task())
        self.assertEqual(self.task()["prompt"], "words from stdin")

    def test_retry_bad_flag_is_usage_error(self):
        tid = self.finish_task()
        r = self.qt("retry", tid, "--nope", "x")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("usage", r.stderr + r.stdout)
        self.assertEqual(self.task()["status"], "done")  # untouched


class TestRetryRefusesRunning(QtMovesBase):
    def test_retry_running_exits_2_and_changes_nothing(self):
        tid, claude_pid, _ = self.start_sleeper()
        before = self.task()
        r = self.qt("retry", tid)
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertEqual(self.task(), before)
        self.assertTrue(_alive(claude_pid))

    def test_retry_queued_exits_2(self):
        tid = self.finish_task()
        p = self.qt_data / "tasks" / f"{tid}.json"
        t = json.loads(p.read_text())
        t["status"] = "queued"
        p.write_text(json.dumps(t))
        self.assertEqual(self.qt("retry", tid).returncode, 2)


class TestHubRecordStopped(unittest.TestCase):
    def setUp(self):
        self.qt = _load_qt_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def _task(self, **kw):
        t = {"id": "261117-094512-who-owns", "prompt": "who owns it", "label": "Who owns it",
             "status": "stopped", "created": "2026-11-17T09:45:12",
             "started": "2026-11-17T09:45:13", "finished": "2026-11-17T09:46:00",
             "result": "Stopped by you", "session_id": None, "origin": "qt"}
        t.update(kw)
        return t

    def test_stopped_maps_to_hub_stopped(self):
        job, body = self.qt._hub_job_record(self._task(), "qt-261117-094512-who-owns", None)
        self.assertEqual(job["status"], "stopped")
        self.assertEqual(job["item_id"], "qt-261117-094512-who-owns")
        self.assertIn("Stopped by you", body)
        self.assertNotIn("error", job)

    def test_stopped_job_lands_on_disk(self):
        jobdir = self.qt._write_hub_job(self.tmp.name, self._task(), None)
        job = json.loads((Path(jobdir) / "job.json").read_text())
        self.assertEqual(job["status"], "stopped")
        self.assertTrue((Path(jobdir) / "output" / "RESULT.md").is_file())

    def test_existing_statuses_unchanged(self):
        job, _ = self.qt._hub_job_record(self._task(status="timeout"), "qt-x", None)
        self.assertEqual((job["status"], job["error"]), ("failed", "timeout"))
        job, _ = self.qt._hub_job_record(self._task(status="done", result="r"), "qt-x", 0)
        self.assertEqual(job["status"], "done")

    def test_cmd_stop_feeds_the_hub(self):
        qt = self.qt
        root = Path(self.tmp.name)
        qt.QT_DATA = str(root)
        qt.TASKS_DIR = str(root / "tasks")
        qt.LOGS_DIR = str(root / "logs")
        qt.WORKSPACE = str(root / "workspace")
        qt.TMP_DIR = str(root / "tmp")
        qt.bootstrap()
        t = self._task(status="running", result=None, pid=None)
        qt.save(t)
        with patch.object(qt, "_feed_hub") as feed:
            qt.cmd_stop(t["id"])
        feed.assert_called_once()
        fed = feed.call_args[0][0]
        self.assertEqual((fed["status"], fed["result"]), ("stopped", "Stopped by you"))


class TestOpenAskUrl(QtMovesBase):
    def setUp(self):
        super().setUp()
        self.hub_dir = Path(self.tmp.name) / "hub"
        self.hub_dir.mkdir()

    def test_open_uses_ask_url_when_hub_configured(self):
        tid = self.finish_task()
        r = self.qt("open", tid, env={"QT_HUB": str(self.hub_dir)})
        self.assertEqual(r.returncode, 0, r.stderr)
        url = f"http://127.0.0.1:8811/ask/qt-{tid}"
        self.assertIn(url, r.stdout)
        self.assertIn(url, self.open_log.read_text())

    def test_open_url_follows_hub_pass_url(self):
        (self.hub_dir / "pass-config.json").write_text(json.dumps({"pass_url": "http://127.0.0.1:9911/"}))
        tid = self.finish_task()
        r = self.qt("open", tid, env={"QT_HUB": str(self.hub_dir)})
        self.assertIn(f"http://127.0.0.1:9911/ask/qt-{tid}", r.stdout)

    def test_open_without_hub_is_unchanged(self):
        tid = self.finish_task(result="the recorded answer")
        r = self.qt("open", tid)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("the recorded answer", r.stdout)
        self.assertNotIn("/ask/", r.stdout)
        self.assertFalse(self.open_log.exists())

    def test_open_falls_back_when_open_fails(self):
        tid = self.finish_task(result="the recorded answer")
        r = self.qt("open", tid, env={"QT_HUB": str(self.hub_dir), "FAKE_OPEN_RC": "1"})
        self.assertIn("the recorded answer", r.stdout)


if __name__ == "__main__":
    unittest.main()
