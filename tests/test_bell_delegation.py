#!/usr/bin/env python3
"""One bell per qt ask (Q5, plan section 1.8): when the configured hub owns
the bell (<hub>/bell.py present), qt skips its own finish / blocked /
failed / timeout / continuation banners -- the hub rings for the ask via
its own notice.py, fed the job record qt just wrote. The DM-fallback
"DM not sent" notice still rings (it reports qt's own Slack send failing,
which the hub has no record of). Standalone qt (no hub) and an old hub
without bell.py keep today's behavior exactly: qt's banners still fire.

End-to-end tests drive the real `qt` script as a subprocess against a
throwaway QT_DATA and a throwaway hub dir (seed.py + items_io.py copied
from the real hub repo; the hub's bell.py is a stub -- qt only checks that
it exists, it never runs it), with a fake `claude` on PATH and no-op
osascript / terminal-notifier shims that log their argv so a test can
prove whether qt's own notify() fired. Nothing here ever pops a real
notification, reads or writes ~/.quicktasks, or touches a live hub.
"""
import live_guard  # noqa: F401  # FIRST: sandboxes QT_DATA, clears QT_HUB, QT_NOTIFY_INBOX=0

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

# The real hub repo: seed.py + items_io.py (source only) are copied into a
# throwaway hub dir so _feed_hub can seed items there. In the main checkout
# it sits next door; in a wave worktree it is one level further up.
_HUB_CANDIDATES = (REPO_ROOT.parent / "hub", REPO_ROOT.parent.parent / "hub")
HUB_REPO = next((p for p in _HUB_CANDIDATES if (p / "seed.py").is_file()), None)

# Same fake claude as test_hub_feed.py: prints canned --output-format json
# (optionally after a sleep, for the timeout case) and exits FAKE_CLAUDE_RC.
FAKE_CLAUDE = """\
#!/usr/bin/env python3
import os, sys, time
time.sleep(float(os.environ.get("FAKE_CLAUDE_SLEEP", "0")))
sys.stdout.write(os.environ.get("FAKE_CLAUDE_JSON", "{}") + "\\n")
sys.exit(int(os.environ.get("FAKE_CLAUDE_RC", "0")))
"""

# No-op osascript / terminal-notifier: notify() must never reach the real
# ones, so these tests never pop a notification on the running machine.
# Each call is logged (with argv) so a test can tell "qt rang" from "qt
# stayed quiet" -- the whole point of this module.
FAKE_NOTIFIER_SHIM = """\
#!/usr/bin/env python3
import os, sys
log = os.environ.get("FAKE_NOTIFY_LOG")
if log:
    with open(log, "a") as f:
        f.write(repr(sys.argv[1:]) + "\\n")
sys.exit(0)
"""

# Stub for the hub side of the seam. qt only checks that bell.py EXISTS
# (the hub rings via its own notice.py, never through qt), so the content
# is a marker, not an implementation.
BELL_STUB = """\
#!/usr/bin/env python3
# stub hub bell for qt's delegation check (plan 1.8); never executed by qt
"""

# The hub's real seed.py imports the whole asks closure (asks, bell,
# reasons, ...), which cannot exist in this fixture's old-hub scenario --
# a hub where bell.py is absent is the entire point. Both hub ages here
# get this pre-bell seed instead: insert the fragment idempotently into
# the items.json beside the script, which is all qt's _seed_hub_item
# needs from any seed.py it meets.
OLD_SEED_STUB = """\
#!/usr/bin/env python3
import json, os, sys
frag = json.load(open(sys.argv[1]))
here = os.path.dirname(os.path.abspath(__file__))
path = os.path.join(here, "items.json")
data = json.load(open(path))
items = data.setdefault("items", [])
if not any(i.get("id") == frag.get("id") for i in items):
    items.insert(0, frag)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)
"""

# Same notice.py boundary stub as test_hub_feed.py: logs the jobdir it was
# handed, never touches Slack or the network. Proves the hub path still
# runs while qt's own banner is skipped.
FAKE_NOTICE_PY = """\
#!/usr/bin/env python3
import os, sys
log = os.environ.get("FAKE_NOTICE_LOG")
if log:
    with open(log, "a") as f:
        f.write(repr(sys.argv[1:]) + "\\n")
sys.exit(0)
"""


def _load_qt_module(name="qt_under_test_bell"):
    """Import qt as a module (not run it) for the unit-level cases, the
    same pattern test_hub_feed.py uses for its mapping rules."""
    loader = importlib.machinery.SourceFileLoader(name, str(QT_SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


# qt builds the osascript banner line via json.dumps, which escapes the
# non-ASCII marks (✓ -> \u2713, ✗ -> \u2717, ⊘ -> \u2298), and the shim
# logs repr(argv), which doubles that literal backslash -- so these are
# the exact forms that land in the log file.
DONE_MARK = r"Quicktask \\u2713"
BLOCKED_MARK = r"Quicktask \\u2298 blocked"
CONTINUED_MARK = r"Quicktask continued \\u2713"


def _exec(path, text):
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


class BellDelegationBase(unittest.TestCase):
    """Shared fixture: throwaway qt data, throwaway hub, fake binaries."""

    def setUp(self):
        if HUB_REPO is None:
            self.skipTest("real hub repo not found next to the checkout")
        TMP_ROOT.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=str(TMP_ROOT))
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.root = root

        self.qt_data = root / "qtdata"
        self.hub_dir = root / "hub"
        self.hub_dir.mkdir()
        # The hub's real seed.py grew an import closure over the asks waves
        # (asks/bell/reasons/...), and this fixture's "old hub" scenario
        # needs a hub where bell.py does not exist -- mutually exclusive
        # with the real seed. These tests assert qt's delegation, not the
        # seed's semantics (that is the hub repo's own suite), so both hub
        # ages get the same minimal pre-bell seed stub: insert the fragment
        # idempotently, next to the script, and nothing else.
        (self.hub_dir / "seed.py").write_text(OLD_SEED_STUB)
        (self.hub_dir / "items.json").write_text(json.dumps({"items": []}))

        # Fake claude + notifier shims. The resolved claude path must not
        # contain "/T/" or find_claude() rejects it as a session-shim path
        # (why this lives under the repo's own tmp/).
        self.bin_dir = root / "bin"
        self.bin_dir.mkdir()
        claude = self.bin_dir / "claude"
        claude.write_text(FAKE_CLAUDE)
        _exec(claude, FAKE_CLAUDE)
        self.assertNotIn("/T/", str(claude))
        for name in ("osascript", "terminal-notifier"):
            shim = self.bin_dir / name
            shim.write_text(FAKE_NOTIFIER_SHIM)
            _exec(shim, FAKE_NOTIFIER_SHIM)

        self.notify_log = root / "notify.log"
        self.notice_log = root / "notice.log"
        # Sandbox the DM-fallback's transcript lookup too: an empty claude
        # config dir means "no transcript" without reading ~/.claude.
        self.claude_config = root / "claude-config"
        self.claude_config.mkdir()

    # -- fixture helpers ---------------------------------------------------

    def _install_bell(self):
        """Stand a bell.py up in the throwaway hub: the presence qt checks."""
        bell = self.hub_dir / "bell.py"
        bell.write_text(BELL_STUB)
        _exec(bell, BELL_STUB)
        return bell

    def _install_fake_notice(self):
        notice = self.hub_dir / "notice.py"
        notice.write_text(FAKE_NOTICE_PY)
        _exec(notice, FAKE_NOTICE_PY)
        return notice

    def _env(self, extra=None, with_hub=True):
        env = dict(os.environ)
        env["QT_DATA"] = str(self.qt_data)
        if with_hub:
            env["QT_HUB"] = str(self.hub_dir)
        else:
            env.pop("QT_HUB", None)
        env["PATH"] = f"{self.bin_dir}:{env.get('PATH', '')}"
        env["QT_NOTIFY_INBOX"] = "0"
        env["QT_LABEL_REFINE"] = "0"
        env["FAKE_NOTIFY_LOG"] = str(self.notify_log)
        env["FAKE_NOTICE_LOG"] = str(self.notice_log)
        env["CLAUDE_CONFIG_DIR"] = str(self.claude_config)
        env.pop("QT_PERMISSIONS", None)
        env.pop("QT_ORIGIN", None)
        env.pop("QT_TIMEOUT", None)
        if extra:
            env.update(extra)
        return env

    def _qt(self, argv, fake_json, fake_rc=0, extra=None, with_hub=True,
            timeout=60):
        env = self._env(extra, with_hub=with_hub)
        env["FAKE_CLAUDE_JSON"] = json.dumps(fake_json)
        env["FAKE_CLAUDE_RC"] = str(fake_rc)
        return subprocess.run(
            [sys.executable, str(QT_SCRIPT)] + argv,
            capture_output=True, text=True, env=env, timeout=timeout,
        )

    def _fire(self, prompt, fake_json, fake_rc=0, extra=None, with_hub=True):
        """`qt -w <prompt>`: the synchronous finish path."""
        return self._qt(["-w", prompt], fake_json, fake_rc=fake_rc,
                        extra=extra, with_hub=with_hub)

    def _the_task(self):
        files = list((self.qt_data / "tasks").glob("*.json"))
        self.assertEqual(len(files), 1, f"expected exactly one task, got {files}")
        return json.loads(files[0].read_text())

    def _notify_text(self):
        return self.notify_log.read_text() if self.notify_log.is_file() else ""

    def _queued_task(self, tid, prompt):
        """A hand-seeded queued task so `qt _run <tid>` exercises the
        non-interactive run path (blocked banners only fire there; `qt -w`
        passes interactive=True)."""
        tasks = self.qt_data / "tasks"
        tasks.mkdir(parents=True, exist_ok=True)
        task = {
            "id": tid, "prompt": prompt, "label": "a queued fixture task",
            "status": "queued", "created": "2026-11-17T12:00:00",
            "origin": "qt", "invoked_from": str(self.root),
            "run_cwd": str(self.root), "perm_mode": "acceptEdits",
            "model": None, "session_id": None, "result": None,
            "cost_usd": None,
        }
        (tasks / f"{tid}.json").write_text(json.dumps(task, indent=2))
        return tid


class TestSkipWhenHubBell(BellDelegationBase):
    """Hub configured AND bell.py present: qt's banners are skipped, the
    hub's notice.py still gets the job record (it does the ringing)."""

    DONE_JSON = {"result": "All done, nothing else needed.",
                 "session_id": "sess-bell-done", "total_cost_usd": 0.02}

    def setUp(self):
        super().setUp()
        self._install_bell()
        self._install_fake_notice()

    def _assert_delegated(self, proc, expected_status, expected_rc):
        self.assertEqual(proc.returncode, expected_rc, proc.stderr)
        task = self._the_task()
        self.assertEqual(task["status"], expected_status)
        # qt stayed quiet...
        self.assertEqual(self._notify_text(), "",
                         "qt rang its own banner with a hub bell wired: "
                         + self._notify_text())
        # ...and the hub path it delegates to still ran: notice.py got the
        # job record, so the hub's bell has something to ring off.
        self.assertTrue(self.notice_log.is_file(),
                        "notice.py never ran; the finish would be silent")

    def test_done_finish_banner_skipped(self):
        proc = self._fire("a task that finishes cleanly", self.DONE_JSON)
        self._assert_delegated(proc, "done", 0)

    def test_failed_finish_banner_skipped(self):
        proc = self._fire(
            "do something that breaks",
            {"result": "Something went wrong internally.", "is_error": True,
             "session_id": "sess-bell-failed"},
            fake_rc=2,
        )
        self._assert_delegated(proc, "failed", 1)

    def test_timeout_banner_skipped(self):
        proc = self._fire(
            "a task that hangs forever",
            {"result": "", "session_id": "sess-bell-timeout"},
            extra={"QT_TIMEOUT": "1", "FAKE_CLAUDE_SLEEP": "3"},
        )
        self._assert_delegated(proc, "timeout", 1)

    def test_question_banner_skipped(self):
        proc = self._fire(
            "a task that ends asking its owner",
            {"result": "I need your call before finishing.\n\nASK: who owns the renewal?",
             "session_id": "sess-bell-question"},
        )
        self._assert_delegated(proc, "question", 1)
        self.assertEqual(self._the_task()["question"], "who owns the renewal?")

    def test_blocked_banner_skipped_noninteractive(self):
        """`qt _run` is the detached (interactive=False) path -- the only
        one where a blocked finish raises notify_blocked today."""
        tid = self._queued_task("261117-120000-blocked-bell",
                                "a task that gets blocked")
        proc = self._qt(["_run", tid], {
            "result": "", "session_id": "sess-bell-blocked",
            "permission_denials": [
                {"tool_name": "Bash", "tool_input": {"command": "rm -rf /"}},
            ],
        })
        self._assert_delegated(proc, "blocked", 0)

    def test_continuation_banner_skipped(self):
        """A follow-up (`qt resume <id> --prompt ...`) is a finish too: no
        'Quicktask continued ✓' banner, while the hub still gets the new
        job record to ring off."""
        proc = self._fire("a task to continue afterwards", self.DONE_JSON)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        task = self._the_task()
        self.assertEqual(task["status"], "done")
        # reset the notice log so the continuation's notice is unambiguous
        self.notice_log.write_text("")

        proc = self._qt(["resume", task["id"], "--prompt", "go further"],
                        {"result": "Went further, all fine.",
                         "session_id": "sess-bell-cont-2"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        task = self._the_task()
        self.assertEqual(task["status"], "done")
        self.assertEqual(len(task["resumes"]), 1)
        self.assertEqual(self._notify_text(), "",
                         "qt rang a continuation banner with a hub bell wired")
        self.assertTrue(self.notice_log.is_file(),
                        "notice.py never ran for the continuation")

    def test_dm_fallback_notice_still_rings(self):
        """The one local banner that survives delegation: the DM-fallback
        'DM not sent' notice reports qt's own Slack send failing, which the
        hub has no record of -- the hub bell cannot ring for it."""
        (self.hub_dir / "pass-config.json").write_text(
            json.dumps({"owner_slack_id": "U000BELLTEST"}))
        proc = self._fire("send me the answer to everything",
                          {"result": "The answer is 42.",
                           "session_id": "sess-bell-dm"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        task = self._the_task()
        self.assertEqual(task["status"], "done")
        self.assertTrue(task["dm_fallback"].startswith("failed:"))

        notify_text = self._notify_text()
        self.assertIn("DM not sent", notify_text)
        # ...and nothing else rang: the DM-fallback notice is the one and
        # only local banner (a finish banner would carry the ✓ mark).
        self.assertEqual(notify_text.count("Quicktask"), 1)
        self.assertNotIn(r"\\u2713", notify_text)

    def test_hub_bell_wired_true_when_bell_present(self):
        qt = _load_qt_module()
        qt.HUB_DIR_ENV = str(self.hub_dir)
        self.assertTrue(qt._hub_bell_wired())

    def test_claude_missing_banner_skipped_unit(self):
        """The claude-CLI-missing failure path, unit level (find_claude()
        falls back to real install paths, so it can't be forced missing
        from PATH in a subprocess test reliably)."""
        qt = _load_qt_module()
        qt.HUB_DIR_ENV = str(self.hub_dir)
        self.assertTrue(qt._hub_bell_wired())
        calls = []
        qt.notify = lambda *a, **k: calls.append(a)
        qt.notify_blocked = lambda *a, **k: calls.append("blocked")
        qt.find_claude = lambda: None
        qt._feed_hub = lambda *a, **k: None
        tid = "261117-120000-noclaude-bell"
        qt.save({"id": tid, "prompt": "a task with no claude",
                 "status": "queued"})
        qt.run_task(tid)
        self.assertEqual(calls, [])
        self.assertEqual(qt.load(tid)["status"], "failed")

    def test_continuation_claude_missing_banner_skipped_unit(self):
        qt = _load_qt_module()
        qt.HUB_DIR_ENV = str(self.hub_dir)
        calls = []
        qt.notify = lambda *a, **k: calls.append(a)
        qt.notify_blocked = lambda *a, **k: calls.append("blocked")
        qt.find_claude = lambda: None
        qt._feed_hub = lambda *a, **k: None
        tid = "261117-120000-noclaude-cont"
        qt.save({"id": tid, "prompt": "a task with no claude to continue",
                 "status": "done", "session_id": "sess-gone"})
        with self.assertRaises(SystemExit):
            qt.cmd_resume_prompt(tid, "go further")
        self.assertEqual(calls, [])


class TestStandaloneStillNotifies(BellDelegationBase):
    """No hub configured: exactly today's behavior, every banner still
    rings (these tests exist to prove the delegation check can't silence a
    standalone qt)."""

    DONE_JSON = {"result": "All done.", "session_id": "sess-standalone",
                 "total_cost_usd": 0.01}

    def test_done_finish_banner_rings(self):
        proc = self._fire("a standalone task that finishes", self.DONE_JSON,
                          with_hub=False)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self._the_task()["status"], "done")
        self.assertIn(DONE_MARK, self._notify_text())

    def test_blocked_banner_rings_noninteractive(self):
        tid = self._queued_task("261117-120001-blocked-solo",
                                "a standalone task that gets blocked")
        proc = self._qt(["_run", tid], {
            "result": "", "session_id": "sess-blocked-solo",
            "permission_denials": [
                {"tool_name": "Bash", "tool_input": {"command": "rm -rf /"}},
            ],
        }, with_hub=False)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self._the_task()["status"], "blocked")
        self.assertIn(BLOCKED_MARK, self._notify_text())

    def test_continuation_banner_rings(self):
        proc = self._fire("a standalone task to continue", self.DONE_JSON,
                          with_hub=False)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        tid = self._the_task()["id"]
        # isolate the continuation's banner from the first finish's
        self.notify_log.write_text("")
        proc = self._qt(["resume", tid, "--prompt", "go further"],
                        {"result": "Went further.", "session_id": "sess-cont-solo"},
                        with_hub=False)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn(CONTINUED_MARK, self._notify_text())

    def test_hub_bell_wired_false_without_hub(self):
        qt = _load_qt_module()
        qt.HUB_DIR_ENV = None  # live_guard clears QT_HUB; standalone
        self.assertFalse(qt._hub_bell_wired())


class TestOldHubStillNotifies(BellDelegationBase):
    """Hub configured but no bell.py (a hub that predates the seam): qt
    keeps ringing -- today's both-ring behavior, nothing silently lost."""

    DONE_JSON = {"result": "All done.", "session_id": "sess-oldhub",
                 "total_cost_usd": 0.01}

    def setUp(self):
        super().setUp()
        # deliberately NO bell.py; a notice.py so the old hub's Slack
        # notice still fires alongside qt's banner, like today.
        self._install_fake_notice()

    def test_done_banner_and_hub_notice_both_ring(self):
        proc = self._fire("a task on an old hub", self.DONE_JSON)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self._the_task()["status"], "done")
        self.assertIn(DONE_MARK, self._notify_text())
        self.assertTrue(self.notice_log.is_file(),
                        "the old hub's notice.py must still run")

    def test_blocked_banner_rings_noninteractive(self):
        tid = self._queued_task("261117-120002-blocked-old",
                                "an old-hub task that gets blocked")
        proc = self._qt(["_run", tid], {
            "result": "", "session_id": "sess-blocked-old",
            "permission_denials": [
                {"tool_name": "Bash", "tool_input": {"command": "rm -rf /"}},
            ],
        })
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self._the_task()["status"], "blocked")
        self.assertIn(BLOCKED_MARK, self._notify_text())

    def test_continuation_banner_rings(self):
        proc = self._fire("an old-hub task to continue", self.DONE_JSON)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        tid = self._the_task()["id"]
        self.notify_log.write_text("")
        proc = self._qt(["resume", tid, "--prompt", "go further"],
                        {"result": "Went further.", "session_id": "sess-cont-old"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn(CONTINUED_MARK, self._notify_text())

    def test_hub_bell_wired_false_without_bell_py(self):
        qt = _load_qt_module()
        qt.HUB_DIR_ENV = str(self.hub_dir)
        self.assertFalse(qt._hub_bell_wired())

    def test_claude_missing_banner_rings_unit(self):
        """The claude-CLI-missing failure still notifies on an old hub."""
        qt = _load_qt_module()
        qt.HUB_DIR_ENV = str(self.hub_dir)
        self.assertFalse(qt._hub_bell_wired())
        calls = []
        qt.notify = lambda *a, **k: calls.append(a)
        qt.notify_blocked = lambda *a, **k: calls.append("blocked")
        qt.find_claude = lambda: None
        qt._feed_hub = lambda *a, **k: None
        tid = "261117-120003-noclaude-old"
        qt.save({"id": tid, "prompt": "an old-hub task with no claude",
                 "status": "queued"})
        qt.run_task(tid)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], "Quicktask failed")
        self.assertEqual(qt.load(tid)["status"], "failed")


if __name__ == "__main__":
    unittest.main()
