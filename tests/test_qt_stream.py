#!/usr/bin/env python3
"""qt streams (Q10, plan slice 4 / section 1.7): every claude run a qt task
can have -- first run (`run_task`), follow-up (`qt resume <id> --prompt`),
and `qt continue` -- asks claude for `--output-format stream-json --verbose`
and lands the events, line by line as they are produced, in
$QT_DATA/logs/<tid>.events.jsonl (`events_path` on the task record, where
the hub's live "now line" reads them mid-run). The final
{"type":"result",...} event is parsed back out of that file by the updated
_parse_claude_run, which also still accepts the plain --output-format json
object (a claude version or stub that emits it degrades to exactly the old
behavior). A timed-out run kills claude's whole leftover tree via the
runner's process group.

End-to-end tests drive the real `qt` script as a subprocess against a
throwaway QT_DATA with a fake `claude` first on PATH (stream mode emits
event lines with a flush after each -- qt redirects claude's stdout
straight into the events file -- and can hang with a child, for the
timeout case); parse tests load qt as a module and call _parse_claude_run
directly. Nothing here reads or writes ~/.quicktasks, the notify inbox, or
any live hub, and no real claude is ever started. live_guard is imported
first so the environment is fenced before qt reads its paths.
"""
import live_guard  # noqa: F401  # FIRST: sandboxes QT_DATA, clears QT_HUB, QT_NOTIFY_INBOX=0

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

REPO_ROOT = Path(__file__).resolve().parent.parent
QT_SCRIPT = REPO_ROOT / "qt"
TMP_ROOT = REPO_ROOT / "tmp"

# Fake claude. FAKE_CLAUDE_STREAM=1: emit stream-json event lines (each
# flushed -- stdout is a file now, so nothing would arrive otherwise), then
# -- after the optional FAKE_CLAUDE_PIDFILE hang -- the final
# {"type":"result",...} event built from FAKE_CLAUDE_RESULT. Without it:
# the canned plain --output-format json object, which the updated
# _parse_claude_run must keep accepting as the fallback path. Argv is
# logged when FAKE_CLAUDE_ARGV is set, same contract as test_qt_moves.py.
FAKE_CLAUDE = """#!/usr/bin/env python3
import json, os, subprocess, sys, time
argv_log = os.environ.get("FAKE_CLAUDE_ARGV")
if argv_log:
    with open(argv_log, "a") as f:
        f.write(json.dumps(sys.argv[1:]) + "\\n")
result = json.loads(os.environ.get(
    "FAKE_CLAUDE_RESULT", json.dumps({"result": "done", "session_id": "sess-1"})))

def emit(line):
    sys.stdout.write(json.dumps(line) + "\\n")
    sys.stdout.flush()

if os.environ.get("FAKE_CLAUDE_STREAM"):
    emit({"type": "system", "subtype": "init", "session_id": result.get("session_id")})
    emit({"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "text", "text": "working on it"}]}})
    emit({"type": "user", "message": {"role": "user", "content": [
        {"type": "tool_result", "content": "ok"}]}})
pidfile = os.environ.get("FAKE_CLAUDE_PIDFILE")
if pidfile:
    child = subprocess.Popen(["sleep", "300"])
    with open(pidfile, "w") as f:
        f.write(f"{os.getpid()} {child.pid}\\n")
    time.sleep(float(os.environ.get("FAKE_CLAUDE_HANG", "300")))
if os.environ.get("FAKE_CLAUDE_STREAM"):
    event = {"type": "result", "subtype": "success"}
    event.update(result)
    emit(event)
else:
    sys.stdout.write(json.dumps(result) + "\\n")
sys.exit(int(os.environ.get("FAKE_CLAUDE_RC", "0")))
"""

# Stand-in for osascript / terminal-notifier: notify() must never reach the
# real ones, so these tests never pop a notification on the running machine.
NOOP_SHIM = """#!/usr/bin/env python3
import sys
sys.exit(0)
"""


def _load_qt_module(name="qt_under_test_stream"):
    loader = importlib.machinery.SourceFileLoader(name, str(QT_SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def _exe(path, text):
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


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


class QtStreamBase(unittest.TestCase):
    """Throwaway QT_DATA, fake claude + notifier shims on PATH."""

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
        _exe(claude, FAKE_CLAUDE)
        self.assertNotIn("/T/", str(claude))
        for name in ("osascript", "terminal-notifier"):
            _exe(self.bin_dir / name, NOOP_SHIM)
        self.pidfile = root / "pids"
        self.argv_log = root / "claude-argv.log"
        self.env = dict(os.environ)
        self.env.update({
            "QT_DATA": str(self.qt_data),
            "PATH": f"{self.bin_dir}:{os.environ.get('PATH', '')}",
            "QT_NOTIFY_INBOX": "0",
            "QT_LABEL_REFINE": "0",
            "FAKE_CLAUDE_ARGV": str(self.argv_log),
            # sandbox the DM-fallback transcript lookup (~/.claude)
            "CLAUDE_CONFIG_DIR": str(root / "claude-config"),
        })
        for k in ("QT_HUB", "QT_PERMISSIONS", "QT_ORIGIN", "QT_PASS_URL",
                  "QT_TIMEOUT", "QT_ALLOW_FILE"):
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

    def result_env(self, result, session_id="sess-9", cost=0.41, stream=True):
        env = {"FAKE_CLAUDE_RESULT": json.dumps(
            {"result": result, "session_id": session_id, "total_cost_usd": cost})}
        if stream:
            env["FAKE_CLAUDE_STREAM"] = "1"
        return env

    def events_lines(self, task):
        path = Path(task["events_path"])
        self.assertTrue(path.is_file(), f"no events file at {path}")
        lines = [json.loads(l) for l in path.read_text().splitlines() if l.strip()]
        self.assertTrue(lines, "events file is empty")
        return lines


class TestEventsWritten(QtStreamBase):
    """A run's stream-json events land in $QT_DATA/logs/<tid>.events.jsonl
    (events_path on the record), live, for all three run kinds."""

    def test_stream_run_writes_events_and_result(self):
        text = "Procurement owns it, through the vendor-renewals alias."
        r = self.qt("-w", "who owns the billing contact for the GitHub renewal",
                    env=self.result_env(text, session_id="sess-9", cost=0.41))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(text, r.stdout)

        t = self.task()
        self.assertEqual(t["status"], "done")
        self.assertEqual(t["result"], text)
        self.assertEqual(t["session_id"], "sess-9")
        self.assertEqual(t["cost_usd"], 0.41)
        self.assertEqual(t["events_path"],
                         str(self.qt_data / "logs" / f"{t['id']}.events.jsonl"))

        lines = self.events_lines(t)
        self.assertEqual(lines[0].get("type"), "system")
        last = lines[-1]
        self.assertEqual(last.get("type"), "result")
        self.assertEqual(last.get("result"), text)
        self.assertEqual(last.get("session_id"), "sess-9")

    def test_events_land_while_the_run_is_still_going(self):
        """The live-line property: the file already holds events (and no
        result event yet) while claude is mid-run -- the hub's now_line
        reads exactly this window."""
        self.pidfile.unlink(missing_ok=True)
        r = self.qt("check the vendor renewal", env={
            "FAKE_CLAUDE_STREAM": "1",
            "FAKE_CLAUDE_RESULT": json.dumps({"result": "later", "session_id": "s"}),
            "FAKE_CLAUDE_PIDFILE": str(self.pidfile),
        })
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(_wait_for(lambda: self.pidfile.is_file()
                                  and len(self.pidfile.read_text().split()) == 2),
                        "fake claude never started")
        t = self.task()
        self.assertEqual(t["status"], "running")
        self.assertIn("events_path", t)

        lines = self.events_lines(t)
        self.assertGreaterEqual(len(lines), 2, lines)  # init + assistant already
        self.assertNotIn("result", [l.get("type") for l in lines],
                         "result event landed before the run finished")

        # stop still works against a streaming run (Q7's group kill)
        r = self.qt("stop", t["id"])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.task()["status"], "stopped")

    def test_argv_requests_stream_json(self):
        r = self.qt("-w", "a task whose argv shape matters",
                    env=self.result_env("ok", session_id="s"))
        self.assertEqual(r.returncode, 0, r.stderr)
        argv = [json.loads(l) for l in self.argv_log.read_text().splitlines()][-1]
        self.assertIn("--output-format", argv)
        self.assertEqual(argv[argv.index("--output-format") + 1], "stream-json")
        self.assertIn("--verbose", argv)
        self.assertIn("--permission-mode", argv)

    def test_resume_prompt_writes_a_fresh_events_run(self):
        first = "the first answer, distinctly worded"
        r = self.qt("-w", "who owns the renewal", env=self.result_env(first))
        self.assertEqual(r.returncode, 0, r.stderr)
        tid = self.tid()

        second = "the continued answer, also distinct"
        r = self.qt("resume", tid, "--prompt", "go further",
                    env=self.result_env(second, session_id="sess-10"))
        self.assertEqual(r.returncode, 0, r.stderr)

        t = self.task()
        self.assertEqual(t["status"], "done")
        self.assertIn(second, t["result"])
        self.assertEqual(len(t["resumes"]), 1)
        self.assertEqual(t["resumes"][0]["rc"], 0)

        # the events file is truncated per run: it holds THIS run's stream,
        # not the previous one's
        lines = self.events_lines(t)
        self.assertEqual(lines[-1].get("type"), "result")
        self.assertEqual(lines[-1].get("result"), second)
        self.assertNotIn(first, Path(t["events_path"]).read_text())

    def test_continue_writes_events_too(self):
        r = self.qt("-w", "a task to continue past a block",
                    env=self.result_env("blocked-ish first pass"))
        self.assertEqual(r.returncode, 0, r.stderr)
        tid = self.tid()

        r = self.qt("continue", tid, "--allow-once", "Bash",
                    env=self.result_env("finished with the tool allowed",
                                        session_id="sess-c"))
        self.assertEqual(r.returncode, 0, r.stderr)
        t = self.task()
        self.assertEqual(t["status"], "done")
        self.assertEqual(t["resumes"][-1]["kind"], "continue")
        lines = self.events_lines(t)
        self.assertEqual(lines[-1].get("type"), "result")
        self.assertEqual(lines[-1].get("result"), "finished with the tool allowed")


class TestResultFromStream(unittest.TestCase):
    """_parse_claude_run over stream-json output (module-level, pure)."""

    def setUp(self):
        self.qt = _load_qt_module()

    def _parse(self, lines, stderr="", rc=0, questions=None):
        stdout = "".join(json.dumps(l) + "\n" for l in lines)
        return self.qt._parse_claude_run(stdout, stderr, rc, questions=questions)

    def _result_event(self, **fields):
        event = {"type": "result", "subtype": "success"}
        event.update(fields)
        return event

    def test_done_from_result_event(self):
        status, raw, text, sid, cost, denials = self._parse([
            {"type": "system", "subtype": "init", "session_id": "sess-s"},
            {"type": "assistant", "message": {"role": "assistant"}},
            self._result_event(result="All sorted.", session_id="sess-s",
                               total_cost_usd=0.17),
        ])
        self.assertEqual(status, "done")
        self.assertEqual(raw, "All sorted.")
        self.assertEqual(text, "All sorted.")
        self.assertEqual(sid, "sess-s")
        self.assertEqual(cost, 0.17)
        self.assertEqual(denials, [])

    def test_is_error_event_maps_failed(self):
        status, raw, text, sid, cost, _ = self._parse([
            self._result_event(result="", is_error=True, session_id="sess-e",
                               total_cost_usd=0.02),
        ])
        self.assertEqual(status, "failed")
        self.assertEqual(sid, "sess-e")

    def test_denials_in_result_event_map_blocked(self):
        status, _, _, _, _, denials = self._parse([
            self._result_event(result="", session_id="s",
                               permission_denials=[
                                   {"tool_name": "Bash", "tool_input": {"command": "x"}}]),
        ])
        self.assertEqual(status, "blocked")
        self.assertEqual(denials, [{"tool_name": "Bash", "tool_input": {"command": "x"}}])

    def test_ask_tail_maps_question(self):
        ask = self._result_event(
            result="Two candidates.\n\nASK: which renewal did you mean?",
            session_id="s")
        status, raw, _, _, _, _ = self._parse([ask], questions=True)
        self.assertEqual(status, "question")
        self.assertEqual(self.qt._question_from_result(raw),
                         "which renewal did you mean?")
        # questions off: the ASK line is just text in a done result
        status, _, _, _, _, _ = self._parse([ask], questions=False)
        self.assertEqual(status, "done")

    def test_partial_stream_without_result_event_maps_failed_with_stderr_tail(self):
        """A stream cut off before its result event (claude killed mid-run):
        nothing parses as a result, so the run maps failed with the stderr
        tail -- never a crash, never a phantom done. The fallback scan can
        still recover the session id from the init event it lands on."""
        status, raw, text, sid, cost, _ = self._parse(
            [{"type": "system", "subtype": "init", "session_id": "sess-gone"}],
            stderr="claude exploded\nbadly", rc=1)
        self.assertEqual(status, "failed")
        self.assertEqual(raw, "")
        self.assertEqual(text, "claude exploded\nbadly")
        self.assertEqual(sid, "sess-gone")  # recovered via the json fallback
        self.assertIsNone(cost)

    def test_junk_lines_and_last_result_event_win(self):
        status, raw, _, sid, _, _ = self._parse([
            {"type": "system", "subtype": "init"},
            "not json at all",
            {"unrelated": "object without a type"},
            self._result_event(result="stale attempt", session_id="s1"),
            self._result_event(result="final answer", session_id="s2"),
        ])
        self.assertEqual(status, "done")
        self.assertEqual(raw, "final answer")
        self.assertEqual(sid, "s2")


class TestJsonStillParses(unittest.TestCase):
    """The plain --output-format json object stays a first-class format:
    the plan's fallback for stream-shape drift between Claude Code
    versions."""

    def setUp(self):
        self.qt = _load_qt_module()

    def test_plain_object_unit(self):
        stdout = json.dumps({"result": "plain and fine", "session_id": "sess-j",
                             "total_cost_usd": 0.05}) + "\n"
        status, raw, text, sid, cost, denials = \
            self.qt._parse_claude_run(stdout, "", 0)
        self.assertEqual(status, "done")
        self.assertEqual(raw, "plain and fine")
        self.assertEqual(sid, "sess-j")
        self.assertEqual(cost, 0.05)
        self.assertEqual(denials, [])

    def test_plain_object_denials_unit(self):
        stdout = json.dumps({"result": "", "session_id": "s",
                             "permission_denials": [
                                 {"tool_name": "WebFetch", "tool_input": {}}]}) + "\n"
        status, _, _, _, _, denials = self.qt._parse_claude_run(stdout, "", 0)
        self.assertEqual(status, "blocked")
        self.assertEqual(denials, [{"tool_name": "WebFetch", "tool_input": {}}])

    def test_plain_json_claude_still_finishes_end_to_end(self):
        """qt asks for stream-json, but a claude that prints the plain json
        object anyway (an older version, a stub) still ends done with its
        result parsed -- the drift-risk fallback, exercised for real."""
        base = TestJsonStillParses._spawn_fixture()
        self.addCleanup(base.tmp.cleanup)
        env = {"FAKE_CLAUDE_RESULT": json.dumps(
            {"result": "plain object answer", "session_id": "sess-plain"})}
        r = base.qt("-w", "a task answered by an old-format claude", env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("plain object answer", r.stdout)
        t = base.task()
        self.assertEqual(t["status"], "done")
        self.assertEqual(t["result"], "plain object answer")
        self.assertEqual(t["session_id"], "sess-plain")
        # the events file just holds whatever claude actually wrote
        self.assertIn("plain object answer",
                      Path(t["events_path"]).read_text())

    def test_plain_json_resume_still_finishes_end_to_end(self):
        base = TestJsonStillParses._spawn_fixture()
        self.addCleanup(base.tmp.cleanup)
        base.qt("-w", "a task to resume with an old-format claude",
                env={"FAKE_CLAUDE_RESULT": json.dumps(
                    {"result": "first", "session_id": "sess-p1"})})
        tid = base.tid()
        r = base.qt("resume", tid, "--prompt", "go further",
                    env={"FAKE_CLAUDE_RESULT": json.dumps(
                        {"result": "resumed plain answer", "session_id": "sess-p2"})})
        self.assertEqual(r.returncode, 0, r.stderr)
        t = base.task()
        self.assertEqual(t["status"], "done")
        self.assertIn("resumed plain answer", t["result"])
        self.assertEqual(t["session_id"], "sess-p2")

    @staticmethod
    def _spawn_fixture():
        """An e2e fixture on demand (unittest would otherwise run the base
        class's no-op tests too if it inherited QtStreamBase)."""
        class _Fixture(QtStreamBase):
            def runTest(self):
                pass
        fixture = _Fixture()
        fixture.setUp()
        return fixture


class TestTimeoutKillsGroup(QtStreamBase):
    """A timed-out run must not leave claude's spawned children alive:
    the runner takes its whole process group down (killpg semantics -- see
    qt's _kill_run_group_mates for why it is not a literal killpg)."""

    def test_timeout_kills_claude_and_its_child(self):
        self.pidfile.unlink(missing_ok=True)
        r = self.qt("a task whose claude hangs with a child", env={
            "FAKE_CLAUDE_STREAM": "1",
            "FAKE_CLAUDE_RESULT": json.dumps({"result": "never", "session_id": "s"}),
            "FAKE_CLAUDE_PIDFILE": str(self.pidfile),
            "QT_TIMEOUT": "1",
        })
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(_wait_for(lambda: self.pidfile.is_file()
                                  and len(self.pidfile.read_text().split()) == 2),
                        "fake claude never started")
        claude_pid, child_pid = (int(x) for x in self.pidfile.read_text().split())
        self.assertTrue(_alive(claude_pid) and _alive(child_pid))

        t = self.task()
        self.assertTrue(_wait_for(lambda: self.task()["status"] == "timeout"),
                        f"run never timed out: {self.task()}")
        self.assertEqual(self.task()["result"], "timed out after 1s")

        # claude died with the timeout, its child with the group kill
        self.assertTrue(_wait_for(lambda: not _alive(claude_pid)),
                        "claude survived its timeout")
        self.assertTrue(_wait_for(lambda: not _alive(child_pid)),
                        "claude's child survived the timeout group kill")

        # the partial stream claude flushed before dying is preserved
        lines = self.events_lines(self.task())
        self.assertEqual(lines[0].get("type"), "system")
        self.assertNotIn("result", [l.get("type") for l in lines])

    def test_foreground_timeout_completes_without_touching_the_terminal_group(self):
        """`qt -w` shares the terminal's process group, so the group kill
        must be a no-op there: the timeout still completes normally (and
        the run still dies), without signaling anything outside the run."""
        self.pidfile.unlink(missing_ok=True)
        r = self.qt("-w", "a task that hangs in the foreground", env={
            "FAKE_CLAUDE_STREAM": "1",
            "FAKE_CLAUDE_RESULT": json.dumps({"result": "never", "session_id": "s"}),
            "FAKE_CLAUDE_PIDFILE": str(self.pidfile),
            "QT_TIMEOUT": "1",
        })
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("[timeout]", r.stdout)
        t = self.task()
        self.assertEqual(t["status"], "timeout")
        self.assertEqual(t["result"], "timed out after 1s")


if __name__ == "__main__":
    unittest.main()
