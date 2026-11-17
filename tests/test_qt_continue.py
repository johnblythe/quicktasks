#!/usr/bin/env python3
"""qt continue (allow-once / skip) and the ASK: question convention.

Runs the real `qt` script as a subprocess against a throwaway QT_DATA with a
fake `claude` first on PATH; the question-mapping tests load qt as a module.
Nothing reads or writes ~/.quicktasks, the notify inbox or a live hub, and no
real claude is started. live_guard is imported first so the environment is
fenced before qt reads its paths.
"""
import live_guard  # noqa: F401  (tests/ is on sys.path under discover)

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

# Logs argv and the --settings file's content (qt deletes that file the
# moment claude returns), then prints canned --output-format json.
FAKE_CLAUDE = """#!/usr/bin/env python3
import json, os, sys
argv = sys.argv[1:]
settings = None
if "--settings" in argv:
    try:
        with open(argv[argv.index("--settings") + 1]) as f:
            settings = json.load(f)
    except (OSError, ValueError):
        settings = None
log = os.environ.get("FAKE_CLAUDE_LOG")
if log:
    with open(log, "a") as f:
        f.write(json.dumps({"argv": argv, "settings": settings}) + "\\n")
sys.stdout.write(os.environ.get("FAKE_CLAUDE_JSON", "{}") + "\\n")
sys.exit(0)
"""

NOOP = "#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n"


def _load_qt(name):
    loader = importlib.machinery.SourceFileLoader(name, str(QT_SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def _exe(path, text):
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


class Base(unittest.TestCase):
    def setUp(self):
        TMP_ROOT.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=str(TMP_ROOT))
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.qt_data = root / "qtdata"
        (self.qt_data / "tasks").mkdir(parents=True)
        self.bin_dir = root / "bin"
        self.bin_dir.mkdir()
        _exe(self.bin_dir / "claude", FAKE_CLAUDE)
        for n in ("osascript", "terminal-notifier", "open"):
            _exe(self.bin_dir / n, NOOP)
        self.log = root / "claude.log"
        self.env = dict(os.environ)
        self.env.update({
            "QT_DATA": str(self.qt_data),
            "PATH": f"{self.bin_dir}:{os.environ.get('PATH', '')}",
            "QT_NOTIFY_INBOX": "0",
            "QT_LABEL_REFINE": "0",
            "FAKE_CLAUDE_LOG": str(self.log),
        })
        for k in ("QT_HUB", "QT_PERMISSIONS", "QT_ORIGIN", "QT_PASS_URL",
                  "QT_TIMEOUT", "QT_ALLOW_FILE"):
            self.env.pop(k, None)

    def qt(self, *args, claude_json=None, env=None):
        e = dict(self.env)
        if claude_json is not None:
            e["FAKE_CLAUDE_JSON"] = json.dumps(claude_json)
        e.update(env or {})
        return subprocess.run([sys.executable, str(QT_SCRIPT), *args],
                              capture_output=True, text=True, env=e, timeout=60)

    def write_task(self, **over):
        t = {"id": "261117-094512-who-owns-the", "prompt": "who owns the billing contact",
             "label": "who owns the billing contact", "status": "blocked",
             "created": "2026-11-17T09:45:12", "origin": "qt",
             "invoked_from": str(self.qt_data), "run_cwd": str(self.qt_data),
             "perm_mode": "acceptEdits", "session_id": "sess-1", "result": "Blocked.",
             "denials": [{"tool_name": "mcp__ld-tools__ld_slack_search", "tool_input": {}}]}
        t.update(over)
        (self.qt_data / "tasks" / f"{t['id']}.json").write_text(json.dumps(t))
        return t["id"]

    def task(self, tid):
        return json.loads((self.qt_data / "tasks" / f"{tid}.json").read_text())

    def runs(self):
        if not self.log.is_file():
            return []
        return [json.loads(l) for l in self.log.read_text().splitlines() if l.strip()]


OK = {"result": "Done it.", "session_id": "sess-2", "total_cost_usd": 0.02}


class TestAllowOnceSettings(Base):
    TOOL = "mcp__claude_ai_Slack__slack_search_users"

    def test_tool_present_only_in_that_runs_settings(self):
        tid = self.write_task()
        r = self.qt("continue", tid, "--allow-once", self.TOOL, claude_json=OK)
        self.assertEqual(r.returncode, 0, r.stderr)
        runs = self.runs()
        self.assertEqual(len(runs), 1)
        argv = runs[0]["argv"]
        self.assertIn("--resume", argv)
        self.assertEqual(argv[argv.index("--resume") + 1], "sess-1")
        self.assertIn(self.TOOL, runs[0]["settings"]["permissions"]["allow"])
        # shipped read-only set still rides along
        self.assertIn("Read", runs[0]["settings"]["permissions"]["allow"])
        # the prompt names the tool
        self.assertIn(self.TOOL, argv[argv.index("-p") + 1])

        # a later plain resume does not carry it
        r = self.qt("resume", tid, "--prompt", "and one more thing", claude_json=OK)
        self.assertEqual(r.returncode, 0, r.stderr)
        later = self.runs()[1]
        allow = (later["settings"] or {}).get("permissions", {}).get("allow", [])
        self.assertNotIn(self.TOOL, allow)

    def test_nothing_persisted(self):
        tid = self.write_task()
        self.qt("continue", tid, "--allow-once", self.TOOL, claude_json=OK)
        self.assertFalse((self.qt_data / "allow.json").exists())
        self.assertEqual(list((self.qt_data / "tmp").glob("slack-guard-*.json")), [])

    def test_multiple_tools_and_resume_record(self):
        tid = self.write_task()
        r = self.qt("continue", tid, "--allow-once", "Bash", "--allow-once", self.TOOL,
                    claude_json=OK)
        self.assertEqual(r.returncode, 0, r.stderr)
        allow = self.runs()[0]["settings"]["permissions"]["allow"]
        self.assertIn("Bash", allow)
        self.assertIn(self.TOOL, allow)
        t = self.task(tid)
        self.assertEqual(t["status"], "done")
        self.assertEqual(t["resumes"][-1]["kind"], "continue")
        self.assertEqual(sorted(t["resumes"][-1]["allow_once"]), sorted(["Bash", self.TOOL]))

    def test_written_even_without_a_guard_script(self):
        mod = _load_qt("qt_continue_noguard")
        mod.TMP_DIR = str(Path(self.tmp.name) / "modtmp")
        mod.resolve_slack_guard_cmd = lambda: (None, None)
        self.assertIsNone(mod.render_slack_guard_settings("t-none"))
        path = mod.render_slack_guard_settings("t-none", allow_once=["Bash"])
        self.addCleanup(lambda: os.path.exists(path) and os.remove(path))
        data = json.loads(Path(path).read_text())
        self.assertIn("Bash", data["permissions"]["allow"])
        self.assertNotIn("hooks", data)

    def test_usage_errors(self):
        tid = self.write_task()
        self.assertNotEqual(self.qt("continue", tid).returncode, 0)
        self.assertNotEqual(self.qt("continue", tid, "--allow-once").returncode, 0)
        self.assertNotEqual(
            self.qt("continue", tid, "--skip", "--allow-once", "Bash").returncode, 0)
        self.assertEqual(self.runs(), [])

    def test_refuses_running_task(self):
        tid = self.write_task(status="running")
        r = self.qt("continue", tid, "--skip")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.runs(), [])


class TestSkipPrompt(Base):
    def test_default_skip_text(self):
        tid = self.write_task()
        r = self.qt("continue", tid, "--skip", claude_json=OK)
        self.assertEqual(r.returncode, 0, r.stderr)
        argv = self.runs()[0]["argv"]
        self.assertEqual(argv[argv.index("-p") + 1],
                         "That tool is not available to you; skip that step and "
                         "finish the rest.")
        self.assertEqual(argv[argv.index("--resume") + 1], "sess-1")
        t = self.task(tid)
        self.assertEqual(t["status"], "done")
        self.assertNotIn("allow_once", t["resumes"][-1])

    def test_skip_adds_no_tools(self):
        tid = self.write_task()
        self.qt("continue", tid, "--skip", claude_json=OK)
        allow = (self.runs()[0]["settings"] or {}).get("permissions", {}).get("allow", [])
        self.assertNotIn("Bash", allow)

    def test_prompt_override(self):
        tid = self.write_task()
        self.qt("continue", tid, "--skip", "--prompt", "skip it, then summarise", claude_json=OK)
        argv = self.runs()[0]["argv"]
        self.assertEqual(argv[argv.index("-p") + 1], "skip it, then summarise")

    def test_hub_job_marks_continue(self):
        hub = Path(self.tmp.name) / "hub"
        (hub / "jobs").mkdir(parents=True)
        _exe(hub / "seed.py", NOOP)  # stand-in: the hub's real seed.py is never run
        tid = self.write_task()
        r = self.qt("continue", tid, "--allow-once", "Bash", claude_json=OK,
                    env={"QT_HUB": str(hub)})
        self.assertEqual(r.returncode, 0, r.stderr)
        jobs = list((hub / "jobs").glob("qt-*/job.json"))
        self.assertEqual(len(jobs), 1)
        job = json.loads(jobs[0].read_text())
        self.assertEqual(job["kind"], "continue")
        self.assertEqual(job["allow_once"], ["Bash"])
        self.assertEqual(job["resume_session"], "sess-1")


class TestQuestionStatus(Base):
    ASK = {"result": "I found two candidates.\n\nASK: Which renewal did you mean?",
           "session_id": "sess-q", "total_cost_usd": 0.03}

    def test_prompt_carries_the_convention(self):
        mod = _load_qt("qt_continue_prompt")
        mod.load_config = lambda: {}
        p = mod.task_prompt({"id": "t1", "prompt": "do x", "invoked_from": "/tmp"})
        self.assertIn("ASK: <question>", p)

    def test_run_ending_in_ask_is_a_question(self):
        r = self.qt("-w", "which renewal is due", claude_json=self.ASK)
        self.assertEqual(r.returncode, 1, r.stderr)  # -w: nonzero unless done
        self.assertIn("[question]", r.stdout)
        files = list((self.qt_data / "tasks").glob("*.json"))
        t = json.loads(files[0].read_text())
        self.assertEqual(t["status"], "question")
        self.assertEqual(t["question"], "Which renewal did you mean?")
        self.assertEqual(t["session_id"], "sess-q")
        # the prompt actually sent includes the convention
        argv = self.runs()[0]["argv"]
        self.assertIn("ASK: <question>", argv[argv.index("-p") + 1])

    def test_ask_must_be_last_line(self):
        r = self.qt("-w", "x", claude_json={"result": "ASK: not last\nfinal answer", "session_id": "s"})
        self.assertEqual(r.returncode, 0, r.stderr)
        files = list((self.qt_data / "tasks").glob("*.json"))
        self.assertEqual(json.loads(files[0].read_text())["status"], "done")

    def test_denials_beat_question(self):
        mod = _load_qt("qt_continue_parse1")
        out = json.dumps({"result": "ASK: ok?", "session_id": "s",
                          "permission_denials": [{"tool_name": "Bash", "tool_input": {}}]})
        self.assertEqual(mod._parse_claude_run(out, "", 0, questions=True)[0], "blocked")

    def test_hub_record_maps_question(self):
        mod = _load_qt("qt_continue_hubrec")
        task = {"id": "t1", "prompt": "p", "label": "p", "status": "question",
                "result": "Looked.\nASK: Which one?", "question": "Which one?",
                "session_id": "s", "created": "2026-11-17T09:00:00",
                "finished": "2026-11-17T09:01:00"}
        job, body = mod._hub_job_record(task, "qt-t1", 0)
        self.assertEqual(job["status"], "question")
        self.assertEqual(job["question"], "Which one?")
        self.assertIn("Which one?", body)

    def test_answering_with_resume_clears_the_question(self):
        r = self.qt("-w", "which renewal", claude_json=self.ASK)
        tid = json.loads(next((self.qt_data / "tasks").glob("*.json")).read_text())["id"]
        r = self.qt("resume", tid, "--prompt", "the GitHub one", claude_json=OK)
        self.assertEqual(r.returncode, 0, r.stderr)
        t = self.task(tid)
        self.assertEqual(t["status"], "done")
        self.assertIsNone(t["question"])

    def test_question_during_continue(self):
        tid = self.write_task()
        r = self.qt("continue", tid, "--skip", claude_json=self.ASK)
        self.assertEqual(r.returncode, 0, r.stderr)
        t = self.task(tid)
        self.assertEqual(t["status"], "question")
        self.assertEqual(t["question"], "Which renewal did you mean?")

    def test_list_glyph(self):
        self.write_task(status="question")
        r = self.qt("list")
        self.assertTrue(r.stdout.startswith("? "), r.stdout)


class TestQuestionDisabled(Base):
    def setUp(self):
        super().setUp()
        (self.qt_data / "config.json").write_text(json.dumps({"questions": False}))

    def test_no_tail_and_ask_stays_done(self):
        r = self.qt("-w", "which renewal",
                    claude_json={"result": "Hmm.\nASK: Which one?", "session_id": "s"})
        self.assertEqual(r.returncode, 0, r.stderr)
        argv = self.runs()[0]["argv"]
        self.assertNotIn("ASK:", argv[argv.index("-p") + 1])
        t = json.loads(next((self.qt_data / "tasks").glob("*.json")).read_text())
        self.assertEqual(t["status"], "done")
        self.assertNotIn("question", t)

    def test_default_is_on(self):
        (self.qt_data / "config.json").write_text("{}")
        mod = _load_qt("qt_continue_default")
        self.assertTrue(mod.questions_enabled())


if __name__ == "__main__":
    unittest.main()
