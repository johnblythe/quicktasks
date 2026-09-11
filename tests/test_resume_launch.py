#!/usr/bin/env python3
"""Resume-launch logging/fallback, the resume-handler LaunchServices sweep
and doctor section, and qt setup's default-model step.

Every subprocess a launch path might reach (cmux, open, osascript,
terminal-notifier, claude) is faked on a throwaway PATH under this repo's
own tmp/ (never the system tempdir: find_claude()/find_cmux() reject any
resolved path containing "/T/", which is exactly where macOS's default
tempdir lives). lsregister is never invoked for real either --
QT_TEST_LSREGISTER_DUMP points _lsregister_dump_text() at a fixture file
instead. Nothing here touches ~/.quicktasks, the real LaunchServices
database, or cmux itself.
"""
import ast
import importlib.machinery
import importlib.util
import json
import os
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

DASHES = "-" * 80

# The exact wording cmux's real CLI uses when its socket control mode
# (default "cmuxOnly") refuses a process with no cmux ancestry.
ACCESS_DENIED_STDERR = "Error: ERROR: Access denied - only processes started inside cmux can connect"

# Stands in for the real cmux CLI. Three subcommands matter: `new-workspace`
# (the actual launch attempt), `workspace list` (the readiness probe
# _cmux_ready polls after nudging cmux open), and `ping` (the outside-cmux
# probe). Each is independently controllable so a test can make the probe
# answer instantly -- skipping
# the real 10s wait _launch_cmux would otherwise sit through -- while the
# launch itself still fails.
FAKE_CMUX = """\
#!/usr/bin/env python3
import os, sys
log = os.environ.get("FAKE_CMUX_LOG")
if log:
    with open(log, "a") as f:
        f.write(repr(sys.argv[1:]) + "\\n")
if len(sys.argv) > 1 and sys.argv[1] == "new-workspace":
    sys.stderr.write(os.environ.get("FAKE_CMUX_NEW_WORKSPACE_STDERR", ""))
    sys.exit(int(os.environ.get("FAKE_CMUX_NEW_WORKSPACE_RC", "0")))
if len(sys.argv) > 2 and sys.argv[1] == "workspace" and sys.argv[2] == "list":
    sys.stderr.write(os.environ.get("FAKE_CMUX_READY_STDERR", ""))
    sys.exit(int(os.environ.get("FAKE_CMUX_READY_RC", "0")))
if len(sys.argv) > 1 and sys.argv[1] == "ping":
    sys.stderr.write(os.environ.get("FAKE_CMUX_PING_STDERR", ""))
    sys.exit(int(os.environ.get("FAKE_CMUX_PING_RC", "0")))
sys.exit(0)
"""

# Stands in for /usr/bin/open. Never launches anything real; just logs what
# it was asked to open so a test can tell cmux's "open -ga cmux" nudge and
# the Terminal.app fallback launch apart.
FAKE_OPEN = """\
#!/usr/bin/env python3
import os, sys
log = os.environ.get("FAKE_OPEN_LOG")
if log:
    with open(log, "a") as f:
        f.write(repr(sys.argv[1:]) + "\\n")
sys.exit(int(os.environ.get("FAKE_OPEN_RC", "0")))
"""

# Stands in for osascript/terminal-notifier: notify() must never pop a real
# notification on whatever machine runs these tests.
FAKE_NOTIFIER_SHIM = """\
#!/usr/bin/env python3
import os, sys
log = os.environ.get("FAKE_NOTIFY_LOG")
if log:
    with open(log, "a") as f:
        f.write(repr(sys.argv[1:]) + "\\n")
sys.exit(0)
"""

# Stands in for the claude CLI for `qt doctor`'s `claude --version` check
# only; nothing here queues a real task.
FAKE_CLAUDE_VERSION = """\
#!/usr/bin/env python3
import sys
sys.stdout.write("2.1.266 (Claude Code)\\n")
sys.exit(0)
"""


def _write_exec(path, text):
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


def _load_qt_module():
    """Import qt as a fresh module object. QT_DATA (and everything derived
    from it: TASKS_DIR, LOGS_DIR, RESUME_LOG, TMP_DIR, CONFIG_PATH, ...) is
    read once at module-exec time, so callers must set os.environ["QT_DATA"]
    beforehand and reload for each new QT_DATA -- following the same
    SourceFileLoader pattern test_hub_feed.py uses for its own pure-function
    checks."""
    loader = importlib.machinery.SourceFileLoader("qt_resume_under_test", str(QT_SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class LaunchInTerminalTests(unittest.TestCase):
    """Drives _launch_in_terminal / _launch_cmux directly against fake
    cmux/open/osascript binaries, so each scenario can inspect resume.log
    and the notification body without parsing qt's stdout."""

    def setUp(self):
        TMP_ROOT.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=str(TMP_ROOT))
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.qt_data = root / "qtdata"

        bin_dir = root / "bin"
        bin_dir.mkdir()
        _write_exec(bin_dir / "cmux", FAKE_CMUX)
        _write_exec(bin_dir / "open", FAKE_OPEN)
        _write_exec(bin_dir / "osascript", FAKE_NOTIFIER_SHIM)
        _write_exec(bin_dir / "terminal-notifier", FAKE_NOTIFIER_SHIM)
        self.assertNotIn("/T/", str(bin_dir))
        self.bin_dir = bin_dir

        self.cmux_log = root / "cmux.log"
        self.open_log = root / "open.log"
        self.notify_log = root / "notify.log"

        self._old_environ = dict(os.environ)
        self.addCleanup(self._restore_environ)
        os.environ["QT_DATA"] = str(self.qt_data)
        os.environ["PATH"] = f"{bin_dir}:{os.environ.get('PATH', '')}"
        os.environ["FAKE_CMUX_LOG"] = str(self.cmux_log)
        os.environ["FAKE_OPEN_LOG"] = str(self.open_log)
        os.environ["FAKE_NOTIFY_LOG"] = str(self.notify_log)

        self.qt = _load_qt_module()
        self.qt.bootstrap()

    def _restore_environ(self):
        os.environ.clear()
        os.environ.update(self._old_environ)

    def _set_terminal(self, terminal):
        self.qt.save_config({"terminal": terminal})

    def _log_records(self):
        if not os.path.exists(self.qt.RESUME_LOG):
            return []
        with open(self.qt.RESUME_LOG) as f:
            return [json.loads(ln) for ln in f if ln.strip()]

    def _read_calls(self, log_path):
        if not log_path.exists():
            return []
        with open(log_path) as f:
            return [ast.literal_eval(ln) for ln in f if ln.strip()]

    def test_cmux_success_logs_cmux_outcome_and_calls_nothing_else(self):
        self._set_terminal("cmux")
        self.qt._launch_in_terminal("resume-t1", "qt t1", [sys.executable, "-c", "pass"])

        records = self._log_records()
        self.assertEqual(len(records), 1)
        rec = records[0]
        self.assertEqual(rec["outcome"], "cmux")
        self.assertEqual(rec["branch"], "cmux")
        self.assertEqual(rec["requested_terminal"], "cmux")
        self.assertEqual(len(rec["attempts"]), 1)
        self.assertEqual(rec["attempts"][0]["rc"], 0)
        self.assertIn("new-workspace", rec["attempts"][0]["argv"])

        # only the one new-workspace call happened: no readiness probe, no
        # "open -ga cmux" nudge, no Terminal fallback, no notification.
        cmux_calls = self._read_calls(self.cmux_log)
        self.assertEqual(len(cmux_calls), 1)
        self.assertFalse(self.open_log.exists())
        self.assertFalse(self.notify_log.exists())

    def test_cmux_new_workspace_failure_falls_back_to_terminal_with_real_reason(self):
        self._set_terminal("cmux")
        os.environ["FAKE_CMUX_NEW_WORKSPACE_RC"] = "2"
        os.environ["FAKE_CMUX_NEW_WORKSPACE_STDERR"] = "boom: workspace exploded"
        os.environ["FAKE_CMUX_READY_RC"] = "0"  # readiness probe answers immediately

        self.qt._launch_in_terminal("resume-t2", "qt t2", [sys.executable, "-c", "pass"])

        records = self._log_records()
        self.assertEqual(len(records), 1)
        rec = records[0]
        self.assertEqual(rec["outcome"], "terminal-fallback")
        self.assertEqual(rec["branch"], "cmux")
        self.assertEqual(rec["rc"], 2)
        self.assertIn("boom: workspace exploded", rec["stderr"])

        # cmux was hit three times: new-workspace, the readiness probe, and
        # the retried new-workspace; open() twice: the "open -ga cmux"
        # nudge and the final Terminal.app fallback.
        cmux_calls = self._read_calls(self.cmux_log)
        self.assertEqual(len(cmux_calls), 3)
        open_calls = self._read_calls(self.open_log)
        self.assertEqual(len(open_calls), 2)
        self.assertEqual(open_calls[0], ["-ga", "cmux"])
        self.assertEqual(open_calls[1][:2], ["-a", "Terminal"])

        # the notification names the real reason -- never a generic
        # "cmux unreachable"
        notify_calls = self._read_calls(self.notify_log)
        self.assertEqual(len(notify_calls), 1)
        body = notify_calls[0][1]
        self.assertIn("cmux new-workspace failed (rc 2): boom: workspace exploded", body)
        self.assertNotIn("cmux unreachable", body)

    def test_missing_cmux_binary_gives_the_real_reason_not_a_generic_one(self):
        self._set_terminal("cmux")
        self.qt.find_cmux = lambda: None  # nothing on PATH claims to be cmux

        ok, reason, attempts = self.qt._launch_cmux("qt t3", [sys.executable, "-c", "pass"])
        self.assertFalse(ok)
        self.assertEqual(reason, "cmux CLI not found")
        self.assertEqual(attempts, [])

        self.qt._launch_in_terminal("resume-t3", "qt t3", [sys.executable, "-c", "pass"])

        records = self._log_records()
        self.assertEqual(len(records), 1)
        rec = records[0]
        self.assertEqual(rec["outcome"], "terminal-fallback")
        self.assertEqual(rec["branch"], "cmux")

        notify_calls = self._read_calls(self.notify_log)
        self.assertEqual(len(notify_calls), 1)
        body = notify_calls[0][1]
        self.assertIn("cmux CLI not found", body)
        self.assertNotIn("cmux unreachable", body)

        # no cmux subprocess was ever attempted -- find_cmux() said there
        # was nothing to call; only the Terminal.app fallback ran.
        self.assertFalse(self.cmux_log.exists())
        open_calls = self._read_calls(self.open_log)
        self.assertEqual(len(open_calls), 1)
        self.assertEqual(open_calls[0][:2], ["-a", "Terminal"])

    def test_access_denied_returns_immediately_without_nudge_or_poll(self):
        self._set_terminal("cmux")
        os.environ["FAKE_CMUX_NEW_WORKSPACE_RC"] = "1"
        os.environ["FAKE_CMUX_NEW_WORKSPACE_STDERR"] = ACCESS_DENIED_STDERR

        ok, reason, attempts = self.qt._launch_cmux("qt t4", [sys.executable, "-c", "pass"])

        self.assertFalse(ok)
        self.assertIn("outside", reason)
        self.assertIn("password", reason)
        # exactly the one new-workspace attempt: no "open -ga cmux" nudge,
        # no readiness poll -- a denial can only ever be denied again.
        self.assertEqual(len(attempts), 1)
        self.assertIn("new-workspace", attempts[0]["argv"])

    def test_access_denied_falls_back_to_terminal_with_the_denial_reason(self):
        self._set_terminal("cmux")
        os.environ["FAKE_CMUX_NEW_WORKSPACE_RC"] = "1"
        os.environ["FAKE_CMUX_NEW_WORKSPACE_STDERR"] = ACCESS_DENIED_STDERR

        self.qt._launch_in_terminal("resume-t4", "qt t4", [sys.executable, "-c", "pass"])

        records = self._log_records()
        self.assertEqual(len(records), 1)
        rec = records[0]
        self.assertEqual(rec["outcome"], "terminal-fallback")
        self.assertEqual(rec["branch"], "cmux")

        # only the Terminal.app fallback ran -- no "open -ga cmux" nudge
        cmux_calls = self._read_calls(self.cmux_log)
        self.assertEqual(len(cmux_calls), 1)
        open_calls = self._read_calls(self.open_log)
        self.assertEqual(len(open_calls), 1)
        self.assertEqual(open_calls[0][:2], ["-a", "Terminal"])

        notify_calls = self._read_calls(self.notify_log)
        self.assertEqual(len(notify_calls), 1)
        body = notify_calls[0][1]
        self.assertIn("outside", body)
        self.assertIn("password", body)
        self.assertNotIn("cmux unreachable", body)

    def test_cold_start_denial_ends_the_readiness_poll_at_once(self):
        # App down for the first attempt (a socket-down error, not a
        # denial), then up and refusing: the poll must stop on the first
        # refusal with the cmuxOnly reason instead of sitting out the 10 s
        # wait and reporting "not answering".
        self._set_terminal("cmux")
        os.environ["FAKE_CMUX_NEW_WORKSPACE_RC"] = "1"
        os.environ["FAKE_CMUX_NEW_WORKSPACE_STDERR"] = "Error: connection refused"
        os.environ["FAKE_CMUX_READY_RC"] = "1"
        os.environ["FAKE_CMUX_READY_STDERR"] = ACCESS_DENIED_STDERR

        ok, reason, attempts = self.qt._launch_cmux("qt t5", [sys.executable, "-c", "pass"])

        self.assertFalse(ok)
        self.assertIn("outside", reason)
        self.assertIn("password", reason)
        self.assertNotIn("not answering", reason)
        # new-workspace, the open -ga nudge, then the one denied probe
        self.assertEqual(len(attempts), 3)
        self.assertEqual(attempts[1]["argv"], ["open", "-ga", "cmux"])
        self.assertIn("Access denied", attempts[2]["stderr"])
        open_calls = self._read_calls(self.open_log)
        self.assertEqual(open_calls[0], ["-ga", "cmux"])

    def test_socket_state_tells_denied_from_down(self):
        cmux = str(self.bin_dir / "cmux")
        os.environ["FAKE_CMUX_READY_RC"] = "1"
        os.environ["FAKE_CMUX_READY_STDERR"] = ACCESS_DENIED_STDERR
        state, stderr = self.qt._cmux_socket_state(cmux)
        self.assertEqual(state, "denied")
        self.assertIn("Access denied", stderr)

        os.environ["FAKE_CMUX_READY_STDERR"] = "Error: connection refused"
        state, _ = self.qt._cmux_socket_state(cmux)
        self.assertEqual(state, "down")

        os.environ["FAKE_CMUX_READY_RC"] = "0"
        state, _ = self.qt._cmux_socket_state(cmux)
        self.assertEqual(state, "ok")


class CmuxOutsideProbeTests(unittest.TestCase):
    """_cmux_outside_probe() double-forks and detaches to launchd before
    calling `cmux ping`, reproducing the ancestry a resume click has.
    Driven against the same FAKE_CMUX shim, controlled via
    FAKE_CMUX_PING_RC / FAKE_CMUX_PING_STDERR."""

    def setUp(self):
        TMP_ROOT.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=str(TMP_ROOT))
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.qt_data = root / "qtdata"

        bin_dir = root / "bin"
        bin_dir.mkdir()
        _write_exec(bin_dir / "cmux", FAKE_CMUX)
        self.assertNotIn("/T/", str(bin_dir))
        self.bin_dir = bin_dir

        self._old_environ = dict(os.environ)
        self.addCleanup(self._restore_environ)
        os.environ["QT_DATA"] = str(self.qt_data)
        os.environ["PATH"] = f"{bin_dir}:{os.environ.get('PATH', '')}"

        self.qt = _load_qt_module()
        self.cmux_path = str(bin_dir / "cmux")

    def _restore_environ(self):
        os.environ.clear()
        os.environ.update(self._old_environ)

    def test_ok_when_ping_succeeds(self):
        os.environ["FAKE_CMUX_PING_RC"] = "0"
        outcome, detail = self.qt._cmux_outside_probe(self.cmux_path, timeout=5)
        self.assertEqual(outcome, "ok")

    def test_denied_when_ping_reports_access_denied(self):
        os.environ["FAKE_CMUX_PING_RC"] = "1"
        os.environ["FAKE_CMUX_PING_STDERR"] = ACCESS_DENIED_STDERR
        outcome, detail = self.qt._cmux_outside_probe(self.cmux_path, timeout=5)
        self.assertEqual(outcome, "denied")
        self.assertIn("Access denied", detail)

    def test_down_on_other_nonzero_exit(self):
        os.environ["FAKE_CMUX_PING_RC"] = "17"
        os.environ["FAKE_CMUX_PING_STDERR"] = "boom: something else broke"
        outcome, detail = self.qt._cmux_outside_probe(self.cmux_path, timeout=5)
        self.assertEqual(outcome, "down")
        self.assertIn("boom: something else broke", detail)


class ResumeLogRotationTests(unittest.TestCase):
    """resume.log keeps at most RESUME_LOG_MAX_LINES records, dropping the
    oldest first -- an unbounded log under a chatty resume habit would
    otherwise grow forever."""

    def setUp(self):
        TMP_ROOT.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=str(TMP_ROOT))
        self.addCleanup(self.tmp.cleanup)
        self.qt_data = Path(self.tmp.name) / "qtdata"

        self._old_environ = dict(os.environ)
        self.addCleanup(self._restore_environ)
        os.environ["QT_DATA"] = str(self.qt_data)

        self.qt = _load_qt_module()

    def _restore_environ(self):
        os.environ.clear()
        os.environ.update(self._old_environ)

    def test_rotates_keeping_the_most_recent_records(self):
        total = self.qt.RESUME_LOG_MAX_LINES + 50
        for i in range(total):
            self.qt._log_launch({"seq": i, "outcome": "cmux"})

        with open(self.qt.RESUME_LOG) as f:
            lines = [ln for ln in f if ln.strip()]
        self.assertEqual(len(lines), self.qt.RESUME_LOG_MAX_LINES)
        self.assertEqual(json.loads(lines[0])["seq"], total - self.qt.RESUME_LOG_MAX_LINES)
        self.assertEqual(json.loads(lines[-1])["seq"], total - 1)


class LsregisterClaimantsParsingTests(unittest.TestCase):
    """Pure-function check of _lsregister_claimants against a hand-built
    fixture matching the real `lsregister -dump` record shape (verified
    against a real, read-only dump during development). Never shells out
    to the real lsregister."""

    def setUp(self):
        self._old_environ = dict(os.environ)
        self.addCleanup(self._restore_environ)
        os.environ["QT_DATA"] = str(TMP_ROOT / "unused-lsregister-parse-qtdata")
        self.qt = _load_qt_module()

    def _restore_environ(self):
        os.environ.clear()
        os.environ.update(self._old_environ)

    def test_extracts_path_and_name_for_each_claimant(self):
        fixture = (
            f"{DASHES}\n"
            "bundle id:                  QuicktaskResume.new (0x3c8c)\n"
            "path:                       /Users/x/.quicktasks/QuicktaskResume.app\n"
            "name:                       QuicktaskResume.new\n"
            "identifier:                 com.quicktasks.resume-handler\n"
            f"{DASHES}\n"
            "bundle id:                  OrbStack (0x184c)\n"
            "path:                       /Applications/OrbStack.app\n"
            "name:                       OrbStack\n"
            "identifier:                 dev.kdrag0n.MacVirt\n"
            f"{DASHES}\n"
            "bundle id:                  QuicktaskResume.stale (0x9999)\n"
            "path:                       /private/tmp/qtdefect_test.app\n"
            "name:                       QuicktaskResume.stale\n"
            "identifier:                 com.quicktasks.resume-handler\n"
            f"{DASHES}\n"
        )
        claimants = self.qt._lsregister_claimants(
            "com.quicktasks.resume-handler", dump_text=fixture)
        self.assertEqual(claimants, [
            {"path": "/Users/x/.quicktasks/QuicktaskResume.app", "name": "QuicktaskResume.new"},
            {"path": "/private/tmp/qtdefect_test.app", "name": "QuicktaskResume.stale"},
        ])

    def test_sweep_skips_the_kept_path_and_unregisters_the_rest(self):
        fixture = (
            f"{DASHES}\n"
            "bundle id:                  QuicktaskResume.new (0x3c8c)\n"
            "path:                       /Users/x/.quicktasks/QuicktaskResume.app\n"
            "identifier:                 com.quicktasks.resume-handler\n"
            f"{DASHES}\n"
            "bundle id:                  QuicktaskResume.stale (0x9999)\n"
            "path:                       /private/tmp/qtdefect_test.app\n"
            "identifier:                 com.quicktasks.resume-handler\n"
            f"{DASHES}\n"
        )
        calls = []

        def fake_run_step(argv, timeout):
            calls.append(argv)
            return 0, ""

        removed = self.qt._sweep_stale_claimants(
            "com.quicktasks.resume-handler",
            "/Users/x/.quicktasks/QuicktaskResume.app",
            dump_text=fixture,
            run_step=fake_run_step,
        )
        self.assertEqual(len(removed), 1)
        self.assertEqual(removed[0]["path"], "/private/tmp/qtdefect_test.app")
        self.assertEqual(removed[0]["rc"], 0)
        # never asked to touch the kept (installed) path, and never called
        # lsregister for real -- fake_run_step stood in for every call
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][-1], "/private/tmp/qtdefect_test.app")


class DoctorCmuxOutsideProbeTests(unittest.TestCase):
    """`qt doctor`'s terminal (cmux) section, driven as a real subprocess
    against a fake cmux CLI whose `ping` subcommand is independently
    controllable -- the same fixture shape _cmux_outside_probe's own tests
    use, but exercised through the actual `qt doctor` entry point."""

    def setUp(self):
        TMP_ROOT.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=str(TMP_ROOT))
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.qt_data = root / "qtdata"
        self.qt_data.mkdir()

        bin_dir = root / "bin"
        bin_dir.mkdir()
        _write_exec(bin_dir / "cmux", FAKE_CMUX)
        _write_exec(bin_dir / "claude", FAKE_CLAUDE_VERSION)
        self.assertNotIn("/T/", str(bin_dir))
        self.bin_dir = bin_dir

        with open(self.qt_data / "config.json", "w") as f:
            json.dump({"terminal": "cmux"}, f)

        # doctor's resume-handler section reads lsregister; point it at a
        # fixture so these tests never touch the real LaunchServices DB.
        self.fixture_path = root / "lsdump_fixture.txt"
        self.fixture_path.write_text(
            f"{DASHES}\n"
            "bundle id:                  QuicktaskResume.new (0x3c8c)\n"
            f"path:                       {self.qt_data / 'QuicktaskResume.app'}\n"
            "name:                       QuicktaskResume.new\n"
            "identifier:                 com.quicktasks.resume-handler\n"
            f"{DASHES}\n"
        )

    def _run_qt_doctor(self, extra_env=None):
        env = dict(os.environ)
        env["QT_DATA"] = str(self.qt_data)
        env["PATH"] = f"{self.bin_dir}:{env.get('PATH', '')}"
        env["QT_TEST_LSREGISTER_DUMP"] = str(self.fixture_path)
        env.pop("QT_HUB", None)
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [sys.executable, str(QT_SCRIPT), "doctor"],
            capture_output=True, text=True, env=env, timeout=30,
        )

    def test_denied_probe_warns_with_the_password_mode_fix(self):
        proc = self._run_qt_doctor({
            "FAKE_CMUX_PING_RC": "1",
            "FAKE_CMUX_PING_STDERR": ACCESS_DENIED_STDERR,
        })
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = proc.stdout
        self.assertIn("terminal (cmux)", out)
        self.assertIn("socket refuses processes started outside cmux", out)
        self.assertIn("Terminal.app", out)
        self.assertIn("password", out)
        self.assertIn("reload-config", out)

    def test_ok_probe_reports_probe_ok(self):
        proc = self._run_qt_doctor({"FAKE_CMUX_PING_RC": "0"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("outside-cmux probe ok", proc.stdout)

    def test_denied_socket_state_warns_without_claiming_the_app_is_down(self):
        # doctor run from a non-cmux terminal: its own `workspace list` is
        # refused. That used to print a green "app not running now".
        proc = self._run_qt_doctor({
            "FAKE_CMUX_READY_RC": "1",
            "FAKE_CMUX_READY_STDERR": ACCESS_DENIED_STDERR,
        })
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("socket refuses processes started outside cmux", proc.stdout)
        self.assertIn("reload-config", proc.stdout)
        self.assertNotIn("app not running now", proc.stdout)


class ResumeHandlerDoctorTests(unittest.TestCase):
    """`qt doctor`'s resume-handler section, driven as a real subprocess
    against a fixture lsregister -dump (QT_TEST_LSREGISTER_DUMP), never
    the real LaunchServices database."""

    def setUp(self):
        TMP_ROOT.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=str(TMP_ROOT))
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.qt_data = root / "qtdata"
        self.qt_data.mkdir()

        bin_dir = root / "bin"
        bin_dir.mkdir()
        _write_exec(bin_dir / "claude", FAKE_CLAUDE_VERSION)
        self.bin_dir = bin_dir

        self.installed_app = self.qt_data / "QuicktaskResume.app"
        self.installed_app.mkdir()
        self.stale_path = str(root / "stale" / "QuicktaskResume.stale.app")

        fixture_text = (
            f"{DASHES}\n"
            "bundle id:                  QuicktaskResume.new (0x3c8c)\n"
            f"path:                       {self.installed_app}\n"
            "name:                       QuicktaskResume.new\n"
            "identifier:                 com.quicktasks.resume-handler\n"
            f"{DASHES}\n"
            "bundle id:                  QuicktaskResume.stale (0x9999)\n"
            f"path:                       {self.stale_path}\n"
            "name:                       QuicktaskResume.stale\n"
            "identifier:                 com.quicktasks.resume-handler\n"
            f"{DASHES}\n"
        )
        self.fixture_path = root / "lsdump_fixture.txt"
        self.fixture_path.write_text(fixture_text)

    def _run_qt_doctor(self):
        env = dict(os.environ)
        env["QT_DATA"] = str(self.qt_data)
        env["PATH"] = f"{self.bin_dir}:{env.get('PATH', '')}"
        env["QT_TEST_LSREGISTER_DUMP"] = str(self.fixture_path)
        env.pop("QT_HUB", None)
        return subprocess.run(
            [sys.executable, str(QT_SCRIPT), "doctor"],
            capture_output=True, text=True, env=env, timeout=30,
        )

    def test_doctor_flags_the_extra_claimant_and_marks_the_installed_one(self):
        proc = self._run_qt_doctor()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = proc.stdout

        self.assertIn(f"QuicktaskResume.new · {self.installed_app} (installed)", out)
        self.assertIn(f"QuicktaskResume.stale · {self.stale_path} (EXTRA)", out)
        self.assertIn("1 extra beside the installed one", out)
        self.assertIn("install-handler now sweeps stale claimants automatically", out)


class SetupDefaultModelTests(unittest.TestCase):
    """qt setup's model-selection step: recommends sonnet[1m] but never
    force-writes it -- blank input must leave an unset model unset, so
    resolution keeps falling through to the claude CLI's own default."""

    def setUp(self):
        TMP_ROOT.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=str(TMP_ROOT))
        self.addCleanup(self.tmp.cleanup)
        self.qt_data = Path(self.tmp.name) / "qtdata"

    def _run_qt_setup(self, stdin_text):
        env = dict(os.environ)
        env["QT_DATA"] = str(self.qt_data)
        env.pop("QT_HUB", None)
        return subprocess.run(
            [sys.executable, str(QT_SCRIPT), "setup"],
            input=stdin_text, capture_output=True, text=True, env=env, timeout=30,
        )

    def _config(self):
        with open(self.qt_data / "config.json") as f:
            return json.load(f)

    def test_recommends_sonnet_1m_and_blank_choice_leaves_model_unset(self):
        # 6 blank answers: terminal, test-launch, trusted-dirs, permissions,
        # model, slack owner id (QT_HUB is unset in _run_qt_setup, so this
        # step asks rather than deferring to the hub's policy). "test
        # launch now? [y/N]" blank means no, so this never actually tries
        # to launch a terminal.
        proc = self._run_qt_setup("\n" * 6)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("sonnet[1m]", proc.stdout)
        self.assertIn("recommended", proc.stdout)

        cfg = self._config()
        self.assertNotIn("model", cfg)
        self.assertIn("model=unset · CLI default", proc.stdout)

    def test_choosing_1_sets_sonnet_1m(self):
        # ...terminal, test-launch, trusted-dirs, permissions, model=1,
        # then a blank slack-owner-id answer (see the 6-answer comment
        # above).
        proc = self._run_qt_setup("\n\n\n\n1\n\n")
        self.assertEqual(proc.returncode, 0, proc.stderr)

        cfg = self._config()
        self.assertEqual(cfg["model"], "sonnet[1m]")
        self.assertIn("model=sonnet[1m]", proc.stdout)


class HubSlugCandidatesTests(unittest.TestCase):
    """Pure-function checks of _hub_slug_candidates: no tasks dir, no
    subprocess, just the string surgery that turns a hub job slug back
    into the ids qt might actually recognize."""

    def setUp(self):
        self._old_environ = dict(os.environ)
        self.addCleanup(self._restore_environ)
        os.environ["QT_DATA"] = str(TMP_ROOT / "unused-hub-slug-candidates-qtdata")
        self.qt = _load_qt_module()

    def _restore_environ(self):
        os.environ.clear()
        os.environ.update(self._old_environ)

    def test_plain_id_yields_nothing_new(self):
        self.assertEqual(
            self.qt._hub_slug_candidates("260909-165637-do-a-deep"), [])

    def test_qt_prefix_alone_is_stripped(self):
        self.assertEqual(
            self.qt._hub_slug_candidates("qt-260909-165637-do-a-deep"),
            ["260909-165637-do-a-deep"])

    def test_trailing_timestamp_alone_is_stripped(self):
        self.assertEqual(
            self.qt._hub_slug_candidates(
                "260909-165637-do-a-deep-20260909-210126"),
            ["260909-165637-do-a-deep"])

    def test_both_prefix_and_timestamp_stripped_together_comes_first(self):
        candidates = self.qt._hub_slug_candidates(
            "qt-260909-165637-do-a-deep-20260909-210126")
        # the fully-stripped id (what the hub actually named the run
        # after) is the first and most likely candidate to try.
        self.assertEqual(candidates[0], "260909-165637-do-a-deep")
        self.assertIn("260909-165637-do-a-deep-20260909-210126", candidates)
        self.assertIn("qt-260909-165637-do-a-deep", candidates)
        self.assertNotIn(
            "qt-260909-165637-do-a-deep-20260909-210126", candidates)


class MatchIdHubSlugTests(unittest.TestCase):
    """match_id against a real (temp) tasks dir: a hub job slug resolves
    to the original quicktask, an exact id still wins over a substring,
    and an unknown fragment still exits the same way it always did."""

    def setUp(self):
        TMP_ROOT.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=str(TMP_ROOT))
        self.addCleanup(self.tmp.cleanup)
        self.qt_data = Path(self.tmp.name) / "qtdata"

        self._old_environ = dict(os.environ)
        self.addCleanup(self._restore_environ)
        os.environ["QT_DATA"] = str(self.qt_data)

        self.qt = _load_qt_module()
        os.makedirs(self.qt.TASKS_DIR, exist_ok=True)

    def _restore_environ(self):
        os.environ.clear()
        os.environ.update(self._old_environ)

    def _make_task(self, tid):
        (Path(self.qt.TASKS_DIR) / f"{tid}.json").write_text("{}")

    def test_hub_slug_resolves_to_the_original_task(self):
        self._make_task("260909-165637-do-a-deep")
        resolved = self.qt.match_id(
            "qt-260909-165637-do-a-deep-20260909-210126")
        self.assertEqual(resolved, "260909-165637-do-a-deep")

    def test_exact_id_still_wins_over_a_substring(self):
        self._make_task("abc")
        self._make_task("abcdef")
        self.assertEqual(self.qt.match_id("abc"), "abc")

    def test_unknown_fragment_exits_with_no_task_matching(self):
        self._make_task("some-other-task")
        with self.assertRaises(SystemExit) as cm:
            self.qt.match_id("qt-nonexistent-20260909-210126")
        self.assertIn("no task matching", str(cm.exception))


class ResumeLaunchNoTaskTests(unittest.TestCase):
    """`qt _resume-launch <id>` (the dispatch a quicktask:// link or a
    blocked-task notification click drives) when the id resolves to
    nothing at all, including every hub-slug candidate. This used to just
    sys.exit with no resume.log record and an easily-missed notification
    as the only signal. Driven as a real subprocess, against the same
    fake cmux/open/osascript/terminal-notifier shims LaunchInTerminalTests
    uses, so the exit code, the resume.log record, and the notification
    are all exercised the way a real click would hit them -- and so a
    passing test proves no fake `open` or `cmux` call ever happened."""

    def setUp(self):
        TMP_ROOT.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=str(TMP_ROOT))
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.qt_data = root / "qtdata"

        bin_dir = root / "bin"
        bin_dir.mkdir()
        _write_exec(bin_dir / "cmux", FAKE_CMUX)
        _write_exec(bin_dir / "open", FAKE_OPEN)
        _write_exec(bin_dir / "osascript", FAKE_NOTIFIER_SHIM)
        _write_exec(bin_dir / "terminal-notifier", FAKE_NOTIFIER_SHIM)
        self.assertNotIn("/T/", str(bin_dir))
        self.bin_dir = bin_dir

        self.cmux_log = root / "cmux.log"
        self.open_log = root / "open.log"
        self.notify_log = root / "notify.log"

        self.env = dict(os.environ)
        self.env["QT_DATA"] = str(self.qt_data)
        self.env["PATH"] = f"{bin_dir}:{self.env.get('PATH', '')}"
        self.env["FAKE_CMUX_LOG"] = str(self.cmux_log)
        self.env["FAKE_OPEN_LOG"] = str(self.open_log)
        self.env["FAKE_NOTIFY_LOG"] = str(self.notify_log)
        self.env.pop("QT_HUB", None)

    def _run_resume_launch(self, fragment):
        return subprocess.run(
            [sys.executable, str(QT_SCRIPT), "_resume-launch", fragment],
            capture_output=True, text=True, env=self.env, timeout=30,
        )

    def _log_records(self):
        resume_log = self.qt_data / "logs" / "resume.log"
        if not resume_log.exists():
            return []
        with open(resume_log) as f:
            return [json.loads(ln) for ln in f if ln.strip()]

    def _read_calls(self, log_path):
        if not log_path.exists():
            return []
        with open(log_path) as f:
            return [ast.literal_eval(ln) for ln in f if ln.strip()]

    def test_unknown_id_logs_no_task_and_notifies_without_launching(self):
        fragment = "qt-260909-165637-do-a-deep-20260909-210126"
        proc = self._run_resume_launch(fragment)

        self.assertNotEqual(proc.returncode, 0)
        self.assertIn(fragment, proc.stderr)

        records = self._log_records()
        self.assertEqual(len(records), 1)
        rec = records[0]
        self.assertEqual(rec["outcome"], "no-task")
        self.assertEqual(rec["fragment"], fragment)
        self.assertIn("260909-165637-do-a-deep", rec["candidates"])

        notify_calls = self._read_calls(self.notify_log)
        self.assertEqual(len(notify_calls), 1)
        body = notify_calls[0][1]
        self.assertIn(fragment, body)
        self.assertIn("qt resume-log", body)

        # no attempt to actually launch anything: no cmux call, no open
        # call (only the notifier's fake osascript ran).
        self.assertFalse(self.cmux_log.exists())
        self.assertFalse(self.open_log.exists())


if __name__ == "__main__":
    unittest.main()
