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
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
QT_SCRIPT = REPO_ROOT / "qt"
TMP_ROOT = REPO_ROOT / "tmp"

DASHES = "-" * 80

# Stands in for the real cmux CLI. Two subcommands matter: `new-workspace`
# (the actual launch attempt) and `workspace list` (the readiness probe
# _cmux_ready polls after nudging cmux open). Each is independently
# controllable so a test can make the probe answer instantly -- skipping
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
    sys.exit(int(os.environ.get("FAKE_CMUX_READY_RC", "0")))
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
        # 5 blank answers: terminal, test-launch, trusted-dirs, permissions,
        # model. "test launch now? [y/N]" blank means no, so this never
        # actually tries to launch a terminal.
        proc = self._run_qt_setup("\n" * 5)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("sonnet[1m]", proc.stdout)
        self.assertIn("recommended", proc.stdout)

        cfg = self._config()
        self.assertNotIn("model", cfg)
        self.assertIn("model=unset · CLI default", proc.stdout)

    def test_choosing_1_sets_sonnet_1m(self):
        proc = self._run_qt_setup("\n\n\n\n1\n")
        self.assertEqual(proc.returncode, 0, proc.stderr)

        cfg = self._config()
        self.assertEqual(cfg["model"], "sonnet[1m]")
        self.assertIn("model=sonnet[1m]", proc.stdout)


if __name__ == "__main__":
    unittest.main()
