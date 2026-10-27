#!/usr/bin/env python3
"""Deterministic Slack DM fallback: the shell enforces "send me" tasks.

Incident (2026-10-26): "read this and send me a simple ELI5 summary
<confluence url>" ran to `done`, but the model never called
mcp__ld-tools__ld_slack_send -- the summary sat in the result text only,
and the hub auto-closed the item as `delivered`, so the owner never saw it.
Prompt instructions alone aren't reliable; run_task() now checks, after the
claude run and before the hub feed, that a requested DM actually went out
and sends the result itself when it didn't.

Four layers, none of which ever reaches Slack:

1. `_asks_for_dm()` / `_is_slack_send_tool()`, the pure detectors.
2. `_slack_send_in_transcript()` against hand-written session transcripts
   (sent / not sent / errored send / missing transcript).
3. `_send_owner_dm()` and `_dm_fallback()` at the unit level, with
   subprocess.run guarded so any real send attempt fails the test, and
   `_send_owner_dm` itself stubbed for the decision tests.
4. `qt -w <prompt>` end to end with a fake claude and a fake `ld` CLI (a
   script that only logs its argv), covering run_task()'s ordering ahead of
   the hub feed and the failure notification.
"""
import importlib.machinery
import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

REPO_ROOT = Path(__file__).resolve().parent.parent
QT_SCRIPT = REPO_ROOT / "qt"
TMP_ROOT = REPO_ROOT / "tmp"

OWNER = "UOWNER001"
SESSION = "11111111-2222-3333-4444-555555555555"
INCIDENT_PROMPT = (
    "read this and send me a simple ELI5 summary "
    "https://launchdarkly.atlassian.net/wiki/spaces/PD/pages/5321654381"
)


def _load_qt_module():
    loader = importlib.machinery.SourceFileLoader("qt_dm_fallback_under_test", str(QT_SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def _write_exec(path, text):
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


def _transcript(*records):
    """JSONL text for a session transcript. Each record is (kind, payload):
    ("use", (tool_use_id, tool_name)), ("result", (tool_use_id, is_error)),
    or ("raw", line) for a line that isn't valid JSON."""
    lines = []
    for kind, payload in records:
        if kind == "use":
            tid, name = payload
            lines.append(json.dumps({"type": "assistant", "message": {"content": [
                {"type": "text", "text": "working"},
                {"type": "tool_use", "id": tid, "name": name, "input": {}},
            ]}}))
        elif kind == "result":
            tid, is_error = payload
            lines.append(json.dumps({"type": "user", "message": {"content": [
                {"type": "tool_result", "tool_use_id": tid, "is_error": is_error, "content": "x"},
            ]}}))
        else:
            lines.append(payload)
    return "\n".join(lines) + "\n"


class DetectorTests(unittest.TestCase):
    def setUp(self):
        self.qt = _load_qt_module()

    def test_the_incident_prompt_asks_for_a_dm(self):
        self.assertTrue(self.qt._asks_for_dm(INCIDENT_PROMPT))

    def test_each_phrase_asks_for_a_dm(self):
        for prompt in (
            "send me the summary",
            "DM me when it's done",
            "slack me a haiku about flags",
            "message me the result",
            "ping me with the answer",
            "Dm Me a recap",
            "SLACK ME the numbers",
            "dm the owner the results",
            "slack the owner a summary",
            "summarize this page and then send me the three bullets",
        ):
            with self.subTest(prompt=prompt):
                self.assertTrue(self.qt._asks_for_dm(prompt))

    def test_plain_tasks_do_not_ask_for_a_dm(self):
        for prompt in (
            "read this and summarize it",
            "fix the flaky test in qt",
            "resend meeting notes to the list",  # "send me" needs a word boundary
            "summarize the #ask-cloud-eng slack channel",
            "send the report to the team",
            "this is a message meant for me",
            "",
            None,
        ):
            with self.subTest(prompt=prompt):
                self.assertFalse(self.qt._asks_for_dm(prompt))

    def test_negated_ask_does_not_count(self):
        for prompt in (
            "summarize this, don't dm me",
            "summarize this, do not send me anything",
            "never slack me about this",
            "summarize this, no need to ping me",
            "summarize this, don’t just message me",
        ):
            with self.subTest(prompt=prompt):
                self.assertFalse(self.qt._asks_for_dm(prompt))

    def test_negation_only_covers_its_own_clause(self):
        self.assertTrue(self.qt._asks_for_dm("don't post publicly. dm me the summary"))

    def test_send_tool_matcher(self):
        for name in (
            "mcp__ld-tools__ld_slack_send",
            "mcp__ld-tools__ld_slack_schedule",
            "mcp__claude_ai_Slack__slack_send_message",
            "mcp__plugin_slack_slack__slack_send_message",
            "mcp__plugin_slack_slack__slack_schedule_message",
        ):
            with self.subTest(name=name):
                self.assertTrue(self.qt._is_slack_send_tool(name))

    def test_non_send_tools_are_not_send_tools(self):
        for name in (
            "mcp__ld-tools__ld_slack_search",
            "mcp__ld-tools__ld_slack_user_by_email",
            "mcp__ld-tools__ld_slack_history",
            "mcp__plugin_slack_slack__slack_send_message_draft",
            "mcp__ld-tools__ld_confluence_page",
            "mcp__sendgrid__lookup",  # "send" in the server name only
            "Read",
            "",
            None,
        ):
            with self.subTest(name=name):
                self.assertFalse(self.qt._is_slack_send_tool(name))


class TranscriptTests(unittest.TestCase):
    def setUp(self):
        self.qt = _load_qt_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.projects = Path(self.tmp.name) / "projects"
        (self.projects / "-Users-someone").mkdir(parents=True)
        self.qt.CLAUDE_PROJECTS_DIR = str(self.projects)

    def _put(self, text, session=SESSION, project="-Users-someone"):
        d = self.projects / project
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{session}.jsonl").write_text(text)

    def test_ld_slack_send_in_transcript_is_sent(self):
        self._put(_transcript(
            ("use", ("t1", "mcp__ld-tools__ld_confluence_page")),
            ("use", ("t2", "mcp__ld-tools__ld_slack_send")),
            ("result", ("t2", False)),
        ))
        self.assertIs(self.qt._slack_send_in_transcript(SESSION), True)

    def test_other_slack_send_tool_is_sent(self):
        self._put(_transcript(("use", ("t1", "mcp__plugin_slack_slack__slack_send_message"))))
        self.assertIs(self.qt._slack_send_in_transcript(SESSION), True)

    def test_no_slack_send_is_not_sent(self):
        # The incident's shape: a Confluence read and nothing else.
        self._put(_transcript(
            ("use", ("t1", "ToolSearch")),
            ("use", ("t2", "mcp__ld-tools__ld_confluence_page")),
            ("result", ("t2", False)),
        ))
        self.assertIs(self.qt._slack_send_in_transcript(SESSION), False)

    def test_slack_reads_and_drafts_are_not_sent(self):
        self._put(_transcript(
            ("use", ("t1", "mcp__ld-tools__ld_slack_user_by_email")),
            ("use", ("t2", "mcp__ld-tools__ld_slack_search")),
            ("use", ("t3", "mcp__plugin_slack_slack__slack_send_message_draft")),
        ))
        self.assertIs(self.qt._slack_send_in_transcript(SESSION), False)

    def test_send_that_errored_is_not_sent(self):
        self._put(_transcript(
            ("use", ("t1", "mcp__ld-tools__ld_slack_send")),
            ("result", ("t1", True)),
        ))
        self.assertIs(self.qt._slack_send_in_transcript(SESSION), False)

    def test_retry_after_errored_send_is_sent(self):
        self._put(_transcript(
            ("use", ("t1", "mcp__ld-tools__ld_slack_send")),
            ("result", ("t1", True)),
            ("use", ("t2", "mcp__ld-tools__ld_slack_send")),
            ("result", ("t2", False)),
        ))
        self.assertIs(self.qt._slack_send_in_transcript(SESSION), True)

    def test_garbage_lines_are_skipped(self):
        self._put(_transcript(
            ("raw", "not json at all"),
            ("raw", json.dumps(["a", "list"])),
            ("raw", json.dumps({"type": "x", "message": "a string"})),
            ("use", ("t1", "mcp__ld-tools__ld_slack_send")),
        ))
        self.assertIs(self.qt._slack_send_in_transcript(SESSION), True)

    def test_transcript_is_found_under_any_project_dir(self):
        self._put(_transcript(("use", ("t1", "mcp__ld-tools__ld_slack_send"))), project="-another-project")
        self.assertIs(self.qt._slack_send_in_transcript(SESSION), True)

    def test_missing_transcript_is_unknown(self):
        self.assertIsNone(self.qt._slack_send_in_transcript(SESSION))

    def test_no_session_id_is_unknown(self):
        self.assertIsNone(self.qt._slack_send_in_transcript(None))
        self.assertIsNone(self.qt._slack_send_in_transcript(""))

    def test_another_sessions_transcript_does_not_count(self):
        self._put(_transcript(("use", ("t1", "mcp__ld-tools__ld_slack_send"))), session="some-other-session")
        self.assertIsNone(self.qt._slack_send_in_transcript(SESSION))


class _NoRealSendMixin:
    """Every subprocess.run in a test goes through a trap: a real send (or
    any other process launch) fails the test instead of reaching Slack."""

    def trap_subprocess(self):
        self.real_runs = []

        def trap(argv, *a, **k):
            self.real_runs.append(argv)
            raise AssertionError(f"unexpected subprocess.run: {argv[:3]}")

        p = patch("subprocess.run", side_effect=trap)
        p.start()
        self.addCleanup(p.stop)
        self.addCleanup(lambda: self.assertEqual(self.real_runs, []))


class SendOwnerDmTests(_NoRealSendMixin, unittest.TestCase):
    def setUp(self):
        self.qt = _load_qt_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.qt.QT_DATA = str(root / "qtdata")
        self.qt.CONFIG_PATH = str(root / "qtdata" / "config.json")
        self.qt.HUB_DIR_ENV = None
        self.calls = []
        self.rc = 0
        self.stderr = ""
        self.timeout = False

        def fake_run(argv, **kwargs):
            self.calls.append((argv, kwargs))
            if self.timeout:
                raise subprocess.TimeoutExpired(argv, kwargs.get("timeout"))
            return types.SimpleNamespace(returncode=self.rc, stdout="1700000000.000100", stderr=self.stderr)

        p = patch("subprocess.run", side_effect=fake_run)
        p.start()
        self.addCleanup(p.stop)

    def _write_qt_config(self, config):
        os.makedirs(os.path.dirname(self.qt.CONFIG_PATH), exist_ok=True)
        with open(self.qt.CONFIG_PATH, "w") as f:
            json.dump(config, f)

    def _hub(self, with_pass_slack=True):
        hub = Path(self.tmp.name) / "hub"
        hub.mkdir()
        if with_pass_slack:
            (hub / "pass-slack.py").write_text("# stub\n")
        self.qt.HUB_DIR_ENV = str(hub)
        return hub

    def test_hub_configured_goes_through_pass_slack(self):
        hub = self._hub()
        self.qt._send_owner_dm(OWNER, "hello")
        argv, kwargs = self.calls[0]
        self.assertEqual(argv, [sys.executable, str(hub.resolve() / "pass-slack.py"), "send", OWNER, "hello"])
        self.assertEqual(len(self.calls), 1)
        self.assertLessEqual(kwargs["timeout"], 60)

    def test_standalone_uses_configured_ld_cli(self):
        self._write_qt_config({"ld_cli": "/opt/research/ld"})
        self.qt._send_owner_dm(OWNER, "- hello")
        # "--" so a message that starts with a dash isn't parsed as a flag.
        self.assertEqual(self.calls[0][0], ["/opt/research/ld", "slack", "send", "--", OWNER, "- hello"])

    def test_hub_without_pass_slack_falls_back_to_ld_cli(self):
        self._hub(with_pass_slack=False)
        self._write_qt_config({"ld_cli": "/opt/research/ld"})
        self.qt._send_owner_dm(OWNER, "hello")
        self.assertEqual(self.calls[0][0][0], "/opt/research/ld")

    def test_no_send_path_raises_without_running_anything(self):
        with self.assertRaisesRegex(RuntimeError, "no way to send"):
            self.qt._send_owner_dm(OWNER, "hello")
        self.assertEqual(self.calls, [])

    def test_nonzero_exit_raises_with_stderr_tail(self):
        self._write_qt_config({"ld_cli": "/opt/research/ld"})
        self.rc, self.stderr = 1, "channel_not_found\n"
        with self.assertRaisesRegex(RuntimeError, "exited 1: channel_not_found"):
            self.qt._send_owner_dm(OWNER, "hello")

    def test_timeout_raises_without_leaking_the_message(self):
        self._write_qt_config({"ld_cli": "/opt/research/ld"})
        self.timeout = True
        with self.assertRaises(RuntimeError) as ctx:
            self.qt._send_owner_dm(OWNER, "a private result body")
        self.assertIn("timed out", str(ctx.exception))
        self.assertNotIn("private result body", str(ctx.exception))


class DmFallbackDecisionTests(_NoRealSendMixin, unittest.TestCase):
    """_dm_fallback() with the send stubbed: only the decision is under test."""

    def setUp(self):
        self.qt = _load_qt_module()
        self.trap_subprocess()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.qt.QT_DATA = str(root / "qtdata")
        self.qt.TASKS_DIR = str(root / "qtdata" / "tasks")
        self.qt.LOGS_DIR = str(root / "qtdata" / "logs")
        self.qt.CONFIG_PATH = str(root / "qtdata" / "config.json")
        self.qt.HUB_DIR_ENV = None
        self.qt.CLAUDE_PROJECTS_DIR = str(root / "projects")
        (root / "projects" / "-p").mkdir(parents=True)
        os.makedirs(self.qt.TASKS_DIR)
        os.makedirs(self.qt.LOGS_DIR)
        self.log_path = os.path.join(self.qt.LOGS_DIR, "t.log")
        with open(self.qt.CONFIG_PATH, "w") as f:
            json.dump({"slack_owner_id": OWNER}, f)

        self.sends = []
        self.send_error = None

        def fake_send(owner_id, text):
            self.sends.append((owner_id, text))
            if self.send_error:
                raise self.send_error

        self.qt._send_owner_dm = fake_send
        self.notifications = []
        self.qt.notify = lambda *a, **k: self.notifications.append((a, k))

    def _task(self, **over):
        task = {
            "id": "261026-200353-read-this-and",
            "prompt": INCIDENT_PROMPT,
            "status": "done",
            "result": "**Pad Thai one-pager**\n\nA school where every kid has a robot helper.",
            "session_id": SESSION,
        }
        task.update(over)
        self.qt.save(task)
        return task

    def _session(self, *records):
        Path(self.qt.CLAUDE_PROJECTS_DIR, "-p", f"{SESSION}.jsonl").write_text(_transcript(*records))

    def _log(self):
        return Path(self.log_path).read_text() if os.path.exists(self.log_path) else ""

    def test_asked_and_not_sent_dms_the_result_with_resume_footer(self):
        self._session(("use", ("t1", "mcp__ld-tools__ld_confluence_page")))
        task = self._task()
        self.qt._dm_fallback(task, self.log_path)

        self.assertEqual(len(self.sends), 1)
        owner_id, text = self.sends[0]
        self.assertEqual(owner_id, OWNER)
        tid = task["id"]
        self.assertTrue(text.startswith(self.qt._DM_FALLBACK_HEADER + "\n\n" + task["result"]))
        self.assertTrue(text.endswith(
            f"↩ resume: `qt resume {tid}` · <quicktask://resume/{tid}|open in terminal>"
        ))
        self.assertEqual(task["dm_fallback"], "sent")
        self.assertEqual(self.qt.load(tid)["dm_fallback"], "sent")
        self.assertEqual(task["status"], "done")
        self.assertIn("dm fallback sent", self._log())
        self.assertEqual(self.notifications, [])

    def test_footer_matches_the_one_task_prompt_asks_the_model_for(self):
        task = self._task()
        self.assertIn(self.qt._resume_footer(task["id"]), self.qt.task_prompt(
            dict(task, invoked_from="/somewhere")))

    def test_model_already_sent_means_no_fallback(self):
        self._session(
            ("use", ("t1", "mcp__ld-tools__ld_slack_send")),
            ("result", ("t1", False)),
        )
        task = self._task()
        self.qt._dm_fallback(task, self.log_path)
        self.assertEqual(self.sends, [])
        self.assertNotIn("dm_fallback", task)
        self.assertNotIn("dm_fallback", self.qt.load(task["id"]))
        self.assertIn("already sent", self._log())

    def test_errored_model_send_still_gets_the_fallback(self):
        self._session(
            ("use", ("t1", "mcp__ld-tools__ld_slack_send")),
            ("result", ("t1", True)),
        )
        self.qt._dm_fallback(self._task(), self.log_path)
        self.assertEqual(len(self.sends), 1)

    def test_missing_transcript_sends_anyway_and_says_so(self):
        # No transcript file written: unknown is treated as "not sent".
        task = self._task()
        self.qt._dm_fallback(task, self.log_path)
        self.assertEqual(len(self.sends), 1)
        self.assertEqual(task["dm_fallback"], "sent")
        self.assertIn("no session transcript found", self._log())

    def test_no_session_id_sends_anyway(self):
        task = self._task(session_id=None)
        self.qt._dm_fallback(task, self.log_path)
        self.assertEqual(len(self.sends), 1)

    def test_task_that_did_not_ask_is_left_alone(self):
        task = self._task(prompt="read this and summarize it")
        self.qt._dm_fallback(task, self.log_path)
        self.assertEqual(self.sends, [])
        self.assertNotIn("dm_fallback", task)
        self.assertEqual(self._log(), "")

    def test_only_a_done_task_gets_the_fallback(self):
        for status in ("failed", "blocked", "timeout", "running"):
            with self.subTest(status=status):
                task = self._task(status=status)
                self.qt._dm_fallback(task, self.log_path)
                self.assertEqual(self.sends, [])
                self.assertNotIn("dm_fallback", task)

    def test_empty_result_is_not_sent(self):
        for result in ("", "   \n", None):
            with self.subTest(result=result):
                task = self._task(result=result)
                self.qt._dm_fallback(task, self.log_path)
                self.assertEqual(self.sends, [])
                self.assertNotIn("dm_fallback", task)

    def test_no_owner_id_configured_means_no_fallback(self):
        with open(self.qt.CONFIG_PATH, "w") as f:
            json.dump({}, f)
        task = self._task()
        self.qt._dm_fallback(task, self.log_path)
        self.assertEqual(self.sends, [])
        self.assertNotIn("dm_fallback", task)
        self.assertEqual(self.notifications, [])

    def test_failed_send_is_recorded_and_notifies_never_silently(self):
        self.send_error = RuntimeError("send exited 1: channel_not_found")
        task = self._task()
        self.qt._dm_fallback(task, self.log_path)  # must not raise

        self.assertEqual(task["status"], "done")
        self.assertEqual(task["dm_fallback"], "failed: send exited 1: channel_not_found")
        self.assertEqual(self.qt.load(task["id"])["dm_fallback"], task["dm_fallback"])
        self.assertIn("dm fallback failed: send exited 1: channel_not_found", self._log())

        self.assertEqual(len(self.notifications), 1)
        (title, subtitle, body), kwargs = self.notifications[0]
        self.assertIn("DM not sent", title)
        self.assertIn(f"qt resume {task['id']}", body)
        self.assertIn("not DM'd", body)
        # A subtitle of its own, so the "Quicktask ✓" notice that follows
        # (grouped by subtitle) can't replace this one.
        self.assertNotEqual(subtitle, task["prompt"])
        self.assertIn(task["id"], kwargs["execute"])

    def test_unexpected_exception_type_is_also_contained(self):
        self.send_error = OSError("no such file: /opt/research/ld")
        task = self._task()
        self.qt._dm_fallback(task, self.log_path)
        self.assertTrue(task["dm_fallback"].startswith("failed: OSError: "))
        self.assertEqual(len(self.notifications), 1)


FAKE_CLAUDE = """\
#!/usr/bin/env python3
import os, sys
sys.stdout.write(os.environ.get("FAKE_CLAUDE_JSON", "{}") + "\\n")
"""

# Stands in for the ld CLI named by config.json's ld_cli: logs its argv and
# exits with FAKE_LD_RC. Never touches Slack or the network.
FAKE_LD = """\
#!/usr/bin/env python3
import json, os, sys
with open(os.environ["FAKE_LD_LOG"], "a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\\n")
sys.stderr.write(os.environ.get("FAKE_LD_STDERR", ""))
sys.exit(int(os.environ.get("FAKE_LD_RC", "0")))
"""

FAKE_NOTIFIER = """\
#!/usr/bin/env python3
import os, sys
with open(os.environ["FAKE_NOTIFY_LOG"], "a") as f:
    f.write(repr(sys.argv[1:]) + "\\n")
"""

# Stands in for the hub's deliver.py: records the task's dm_fallback field as
# of the moment the hub feed ran (RESULT.md and job.json are already written
# by then; the qt task JSON is the thing that must already carry the mark).
FAKE_DELIVER = """\
#!/usr/bin/env python3
import os, sys
with open(os.environ["FAKE_DELIVER_LOG"], "a") as f:
    f.write(open(os.environ["FAKE_LD_LOG"]).read() if os.path.exists(os.environ["FAKE_LD_LOG"]) else "NO-DM-YET")
    f.write("\\n--deliver--\\n")
"""


class RunTaskDmFallbackEndToEndTests(unittest.TestCase):
    """`qt -w <prompt>` with a fake claude and a fake ld CLI."""

    def setUp(self):
        TMP_ROOT.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=str(TMP_ROOT))
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.qt_data = root / "qtdata"
        self.qt_data.mkdir()
        self.claude_cfg = root / "claude-config"
        (self.claude_cfg / "projects" / "-p").mkdir(parents=True)

        bin_dir = root / "bin"
        bin_dir.mkdir()
        self.assertNotIn("/T/", str(bin_dir))
        _write_exec(bin_dir / "claude", FAKE_CLAUDE)
        for name in ("osascript", "terminal-notifier"):
            _write_exec(bin_dir / name, FAKE_NOTIFIER)
        self.bin_dir = bin_dir
        self.ld = root / "fake-ld"
        _write_exec(self.ld, FAKE_LD)
        self.ld_log = root / "ld.log"
        self.notify_log = root / "notify.log"
        (self.qt_data / "config.json").write_text(json.dumps({
            "slack_owner_id": OWNER, "ld_cli": str(self.ld),
        }))

    def _run_qt(self, prompt, *, result="the ELI5 summary", ld_rc=0, extra_env=None):
        env = dict(os.environ)
        env.update(
            QT_DATA=str(self.qt_data),
            PATH=f"{self.bin_dir}:{env.get('PATH', '')}",
            CLAUDE_CONFIG_DIR=str(self.claude_cfg),
            FAKE_CLAUDE_JSON=json.dumps({"result": result, "session_id": SESSION}),
            FAKE_LD_LOG=str(self.ld_log),
            FAKE_LD_RC=str(ld_rc),
            FAKE_LD_STDERR="not_authed\n" if ld_rc else "",
            FAKE_NOTIFY_LOG=str(self.notify_log),
        )
        for k in ("QT_HUB", "QT_PERMISSIONS", "QT_ORIGIN"):
            env.pop(k, None)
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [sys.executable, str(QT_SCRIPT), "-w", prompt],
            capture_output=True, text=True, env=env, timeout=60,
        )

    def _ld_calls(self):
        if not self.ld_log.exists():
            return []
        return [json.loads(l) for l in self.ld_log.read_text().splitlines()]

    def _task(self):
        files = sorted((self.qt_data / "tasks").glob("*.json"))
        self.assertEqual(len(files), 1)
        return json.loads(files[0].read_text())

    def test_asked_for_dm_but_model_sent_nothing_gets_exactly_one_shell_dm(self):
        proc = self._run_qt(INCIDENT_PROMPT)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        calls = self._ld_calls()
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:4], ["slack", "send", "--", OWNER])
        task = self._task()
        self.assertIn(f"qt resume {task['id']}", calls[0][4])
        self.assertTrue(calls[0][4].startswith("_Sent by qt:"))
        self.assertIn("\n\nthe ELI5 summary", calls[0][4])
        self.assertEqual(task["dm_fallback"], "sent")
        self.assertEqual(task["status"], "done")

    def test_model_already_sent_no_shell_dm(self):
        (self.claude_cfg / "projects" / "-p" / f"{SESSION}.jsonl").write_text(_transcript(
            ("use", ("t1", "mcp__ld-tools__ld_slack_send")),
            ("result", ("t1", False)),
        ))
        proc = self._run_qt(INCIDENT_PROMPT)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self._ld_calls(), [])
        self.assertNotIn("dm_fallback", self._task())

    def test_task_that_never_asked_sends_nothing(self):
        proc = self._run_qt("read this and summarize it")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self._ld_calls(), [])

    def test_failed_send_notifies_and_does_not_fail_the_task(self):
        proc = self._run_qt(INCIDENT_PROMPT, ld_rc=1)
        self.assertEqual(proc.returncode, 0, proc.stderr)  # task still done
        task = self._task()
        self.assertEqual(task["status"], "done")
        self.assertTrue(task["dm_fallback"].startswith("failed: send exited 1"), task["dm_fallback"])
        self.assertIn("not_authed", task["dm_fallback"])
        notes = self.notify_log.read_text()
        self.assertIn("DM not sent", notes)
        self.assertIn(f"qt resume {task['id']}", notes)
        log = (self.qt_data / "logs" / (task["id"] + ".log")).read_text()
        self.assertIn("dm fallback failed", log)

    def test_dm_lands_before_the_hub_deliver_step(self):
        hub = Path(self.tmp.name) / "hub"
        hub.mkdir()
        (hub / "pass-config.json").write_text(json.dumps({"owner_slack_id": OWNER}))
        (hub / "seed.py").write_text("import sys\nsys.exit(0)\n")
        # The hub path sends through pass-slack.py; this stand-in logs the
        # same way the fake ld does, so ordering is visible in one file.
        (hub / "pass-slack.py").write_text(
            "import json, os, sys\n"
            "open(os.environ['FAKE_LD_LOG'], 'a').write(json.dumps(sys.argv[1:]) + '\\n')\n"
        )
        _write_exec(hub / "deliver.py", FAKE_DELIVER)
        deliver_log = Path(self.tmp.name) / "deliver.log"
        proc = self._run_qt(INCIDENT_PROMPT, extra_env={
            "QT_HUB": str(hub), "FAKE_DELIVER_LOG": str(deliver_log),
        })
        self.assertEqual(proc.returncode, 0, proc.stderr)
        seen_at_deliver = deliver_log.read_text()
        self.assertIn(OWNER, seen_at_deliver)
        self.assertNotIn("NO-DM-YET", seen_at_deliver)
        calls = self._ld_calls()
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:2], ["send", OWNER])
        self.assertIn(f"qt resume {self._task()['id']}", calls[0][2])


if __name__ == "__main__":
    unittest.main()
