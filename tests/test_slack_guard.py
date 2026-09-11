#!/usr/bin/env python3
"""LD-224 follow-up: quick-fires run under a Slack guard.

Incident: a quick-fire fired from the widget's quick-fire panel posted to
a public Slack channel, because qt's headless `claude -p` launch carried
no PreToolUse hook at all -- only `--permission-mode`, with no tool
allowlist and no `--settings`. Hub-fired jobs already gate every Slack
send through the hub's own guard.py; quick-fires never had an equivalent.

Three things get tested:

1. `qt-guard.py` itself (used when no hub is configured) -- every
   allow/deny branch, driven as a real subprocess against a throwaway
   QT_DATA/config.json, the same stdin/exit-code contract Claude Code's
   PreToolUse hook uses.
2. `resolve_slack_guard_cmd()` / `render_slack_guard_settings()` in `qt`,
   at the unit level (module import, following the hub repo's own test
   style) -- which guard gets picked, and the settings file's shape.
3. The exact argv a real `qt -w <prompt>` run hands to `claude -p`, driven
   end to end with a fake `claude` that captures its own argv and reads
   the referenced --settings file's contents before qt deletes it (qt
   removes that file in a `finally` right after the subprocess returns,
   so nothing outside the fake claude process can observe it afterward).

`qt doctor`'s "Slack guard" line is checked the same end-to-end way.
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
QT_GUARD_SCRIPT = REPO_ROOT / "qt-guard.py"
TMP_ROOT = REPO_ROOT / "tmp"


def _load_qt_module():
    """Import qt as a module (rather than running it), following the same
    pattern test_hub_feed.py uses for the pure helper functions."""
    loader = importlib.machinery.SourceFileLoader("qt_slack_guard_under_test", str(QT_SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def _write_exec(path, text):
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


# Stands in for the claude CLI end to end: captures its own argv, and --
# critically -- reads the --settings file's contents itself, since real
# run_task() deletes that file in a `finally` the instant this process
# returns, before the outer test process could ever read it back.
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

# notify() must never pop a real notification while these tests run.
FAKE_NOTIFIER_SHIM = """\
#!/usr/bin/env python3
import sys
sys.exit(0)
"""

# `qt doctor`'s `claude --version` check only.
FAKE_CLAUDE_VERSION = """\
#!/usr/bin/env python3
import sys
sys.stdout.write("2.1.266 (Claude Code)\\n")
sys.exit(0)
"""


class QtGuardScriptTests(unittest.TestCase):
    """qt-guard.py driven as a real subprocess, the same stdin/exit-code
    contract Claude Code's PreToolUse hook uses (allow: exit 0, deny:
    exit nonzero + a one-line stderr reason)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.qt_data = Path(self.tmp.name)

    def _ask(self, tool_name, tool_input, config=None):
        if config is not None:
            (self.qt_data / "config.json").write_text(json.dumps(config))
        env = dict(os.environ)
        env["QT_DATA"] = str(self.qt_data)
        return subprocess.run(
            [sys.executable, str(QT_GUARD_SCRIPT)],
            input=json.dumps({"tool_name": tool_name, "tool_input": tool_input}),
            capture_output=True, text=True, env=env, timeout=10,
        )

    def test_no_config_at_all_denies_every_write(self):
        proc = self._ask("mcp__ld-tools__ld_slack_send", {"channel": "U999"})
        self.assertEqual(proc.returncode, 2)
        self.assertIn("slack_owner_id", proc.stderr)

    def test_config_present_but_no_owner_id_denies_every_write(self):
        proc = self._ask("mcp__ld-tools__ld_slack_send", {"channel": "U999"}, config={})
        self.assertEqual(proc.returncode, 2)
        self.assertIn("qt setup", proc.stderr)
        self.assertIn("slack_owner_id", proc.stderr)

    def test_owner_dm_is_allowed(self):
        proc = self._ask("mcp__ld-tools__ld_slack_send", {"channel": "U123"},
                          config={"slack_owner_id": "U123"})
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_other_channel_is_denied(self):
        proc = self._ask("mcp__ld-tools__ld_slack_send", {"channel": "C0PUBLIC"},
                          config={"slack_owner_id": "U123"})
        self.assertEqual(proc.returncode, 2)
        self.assertIn("C0PUBLIC", proc.stderr)
        self.assertIn("slack_allowed_channels", proc.stderr)

    def test_allowed_channels_list_permits_a_channel(self):
        proc = self._ask("mcp__ld-tools__ld_slack_send", {"channel": "C0HOME"},
                          config={"slack_owner_id": "U123", "slack_allowed_channels": ["C0HOME"]})
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_public_opt_in_permits_any_channel(self):
        proc = self._ask("mcp__ld-tools__ld_slack_send", {"channel": "C0ANYTHING"},
                          config={"slack_owner_id": "U123", "slack_allow_public_channels": True})
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_missing_channel_field_denied_by_default(self):
        proc = self._ask("mcp__ld-tools__ld_slack_schedule", {},
                          config={"slack_owner_id": "U123"})
        self.assertEqual(proc.returncode, 2)
        self.assertIn("slack_allow_public_channels", proc.stderr)

    def test_missing_channel_field_allowed_with_public_opt_in(self):
        proc = self._ask("mcp__ld-tools__ld_slack_schedule", {},
                          config={"slack_owner_id": "U123", "slack_allow_public_channels": True})
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_channel_id_field_is_also_checked(self):
        proc = self._ask("mcp__ld-tools__ld_slack_react", {"channel_id": "U123"},
                          config={"slack_owner_id": "U123"})
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_read_tools_always_allowed_regardless_of_config(self):
        for name in ("search", "history", "thread", "threads", "channel_info", "channels",
                     "mentions", "unreads", "pins", "reactions_get", "files",
                     "user_by_email", "usergroups", "users_conversations",
                     "channel_members", "expand"):
            proc = self._ask(f"mcp__ld-tools__ld_slack_{name}", {}, config={})
            self.assertEqual(proc.returncode, 0, f"{name}: {proc.stderr}")

    def test_non_slack_tool_passes_through(self):
        proc = self._ask("Bash", {"command": "ls"}, config={"slack_owner_id": "U123"})
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_malformed_stdin_is_denied(self):
        env = dict(os.environ)
        env["QT_DATA"] = str(self.qt_data)
        proc = subprocess.run([sys.executable, str(QT_GUARD_SCRIPT)], input="not json",
                               capture_output=True, text=True, env=env, timeout=10)
        self.assertEqual(proc.returncode, 2)


class ResolveSlackGuardCmdUnitTests(unittest.TestCase):
    """resolve_slack_guard_cmd()'s hub-vs-qt selection and
    render_slack_guard_settings()'s file, at the module level -- cheaper
    and more precise than forcing every branch through a real subprocess."""

    def setUp(self):
        self.mod = _load_qt_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.mod.QT_DATA = str(root / "qtdata")
        self.mod.CONFIG_PATH = str(root / "qtdata" / "config.json")
        self.mod.TMP_DIR = str(root / "qtdata" / "tmp")
        self.mod.HUB_DIR_ENV = None
        # No qt-guard.py neighbor by default -- tests that want the real
        # one reset __file__ back to the actual repo script below.
        no_neighbor = root / "no-neighbor"
        no_neighbor.mkdir()
        self.mod.__file__ = str(no_neighbor / "qt")

    def test_neither_guard_present_returns_none(self):
        self.assertEqual(self.mod.resolve_slack_guard_cmd(), (None, None))
        self.assertIsNone(self.mod.render_slack_guard_settings("tid-none"))

    def test_qt_guard_chosen_when_hub_not_configured(self):
        self.mod.__file__ = str(QT_SCRIPT)
        path, source = self.mod.resolve_slack_guard_cmd()
        self.assertEqual(source, "qt")
        self.assertEqual(Path(path).resolve(), QT_GUARD_SCRIPT.resolve())

    def test_hub_guard_chosen_when_hub_configured_and_guard_py_present(self):
        hub_dir = Path(self.tmp.name) / "hub"
        hub_dir.mkdir()
        (hub_dir / "guard.py").write_text("# fake hub guard\n")
        self.mod.HUB_DIR_ENV = str(hub_dir)
        path, source = self.mod.resolve_slack_guard_cmd()
        self.assertEqual(source, "hub")
        # resolve_hub_dir() realpath()s hub_dir (macOS: /var -> /private/var),
        # so compare resolved paths rather than the raw fixture path.
        self.assertEqual(Path(path).resolve(), (hub_dir / "guard.py").resolve())

    def test_qt_guard_used_when_hub_configured_but_guard_py_missing(self):
        hub_dir = Path(self.tmp.name) / "hub-no-guard"
        hub_dir.mkdir()
        self.mod.HUB_DIR_ENV = str(hub_dir)
        self.mod.__file__ = str(QT_SCRIPT)
        path, source = self.mod.resolve_slack_guard_cmd()
        self.assertEqual(source, "qt")

    def test_render_settings_shape_and_matcher(self):
        self.mod.__file__ = str(QT_SCRIPT)
        path = self.mod.render_slack_guard_settings("tid-abc")
        self.addCleanup(lambda: os.path.exists(path) and os.remove(path))
        self.assertTrue(os.path.isfile(path))
        data = json.loads(Path(path).read_text())
        hooks = data["hooks"]["PreToolUse"]
        self.assertEqual(len(hooks), 1)
        self.assertEqual(hooks[0]["matcher"], self.mod.SLACK_GUARD_MATCHER)
        self.assertEqual(hooks[0]["matcher"], "mcp__ld-tools__ld_slack_.*")
        command = hooks[0]["hooks"][0]["command"]
        self.assertEqual(hooks[0]["hooks"][0]["type"], "command")
        self.assertIn("qt-guard.py", command)

    def test_render_settings_hub_guard_referenced_when_hub_configured(self):
        hub_dir = Path(self.tmp.name) / "hub"
        hub_dir.mkdir()
        (hub_dir / "guard.py").write_text("# fake hub guard\n")
        self.mod.HUB_DIR_ENV = str(hub_dir)
        path = self.mod.render_slack_guard_settings("tid-hub")
        self.addCleanup(lambda: os.path.exists(path) and os.remove(path))
        command = json.loads(Path(path).read_text())["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
        self.assertIn(str(hub_dir / "guard.py"), command)

    def test_render_settings_path_unique_per_task_id(self):
        self.mod.__file__ = str(QT_SCRIPT)
        p1 = self.mod.render_slack_guard_settings("tid-one")
        p2 = self.mod.render_slack_guard_settings("tid-two")
        self.addCleanup(lambda: os.path.exists(p1) and os.remove(p1))
        self.addCleanup(lambda: os.path.exists(p2) and os.remove(p2))
        self.assertNotEqual(p1, p2)

    def test_render_settings_lands_under_qt_data_tmp(self):
        self.mod.__file__ = str(QT_SCRIPT)
        path = self.mod.render_slack_guard_settings("tid-loc")
        self.addCleanup(lambda: os.path.exists(path) and os.remove(path))
        self.assertEqual(os.path.dirname(path), self.mod.TMP_DIR)

    def test_render_settings_includes_permission_allow_list(self):
        """A fresh install has no personal allow rule for mcp__ld-tools__*,
        so render_slack_guard_settings() must carry its own permissions.
        allow list (QT_TOOLS_ALLOW) alongside the guard hook -- otherwise
        the very first quick-fire that touches an ld-tools MCP call is
        denied outright, which is exactly this incident."""
        self.mod.__file__ = str(QT_SCRIPT)
        path = self.mod.render_slack_guard_settings("tid-allow")
        self.addCleanup(lambda: os.path.exists(path) and os.remove(path))
        data = json.loads(Path(path).read_text())
        allow = data["permissions"]["allow"]
        self.assertEqual(allow, self.mod.QT_TOOLS_ALLOW)
        for name in (
            "Read",
            "mcp__ld-tools__ld_research",
            "mcp__ld-tools__ld_slack_search",
            "mcp__ld-tools__ld_slack_send",
            "mcp__ld-tools__ld_slack_user_by_email",
        ):
            self.assertIn(name, allow)
        # The hook is still doing the Slack-destination gating; the allow
        # list only fills the fresh-install permission gap.
        self.assertIn("hooks", data)


class TaskPromptOwnerIdTests(unittest.TestCase):
    """task_prompt()'s owner-id note (see resolve_owner_slack_id()): once
    the prompt names the owner's Slack id directly, a "slack me" quick-
    fire should never need to call mcp__ld-tools__ld_slack_user_by_email
    to find out who to message -- the exact lookup this incident's run
    was denied on."""

    def setUp(self):
        self.mod = _load_qt_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.mod.QT_DATA = str(root / "qtdata")
        self.mod.CONFIG_PATH = str(root / "qtdata" / "config.json")
        self.mod.HUB_DIR_ENV = None

    def _task(self, prompt="do the thing"):
        return {
            "id": "tid-prompt",
            "prompt": prompt,
            "invoked_from": str(Path(self.tmp.name)),
        }

    def _write_qt_config(self, config):
        os.makedirs(os.path.dirname(self.mod.CONFIG_PATH), exist_ok=True)
        with open(self.mod.CONFIG_PATH, "w") as f:
            json.dump(config, f)

    def test_standalone_config_owner_id_is_named_in_prompt(self):
        self._write_qt_config({"slack_owner_id": "U123STANDALONE"})
        prompt = self.mod.task_prompt(self._task())
        self.assertIn("U123STANDALONE", prompt)
        self.assertIn("mcp__ld-tools__ld_slack_send", prompt)
        self.assertNotIn("unavailable", prompt)

    def test_hub_config_owner_id_is_named_in_prompt(self):
        hub_dir = Path(self.tmp.name) / "hub"
        hub_dir.mkdir()
        (hub_dir / "pass-config.json").write_text(json.dumps({"owner_slack_id": "U999HUB"}))
        self.mod.HUB_DIR_ENV = str(hub_dir)
        prompt = self.mod.task_prompt(self._task())
        self.assertIn("U999HUB", prompt)
        self.assertNotIn("unavailable", prompt)

    def test_hub_config_without_owner_id_does_not_fall_back_to_qt_config(self):
        # Hub configured but pass-config.json has no owner_slack_id: this
        # must report unavailable, not silently read qt's own config.json.
        self._write_qt_config({"slack_owner_id": "U123STANDALONE"})
        hub_dir = Path(self.tmp.name) / "hub"
        hub_dir.mkdir()
        (hub_dir / "pass-config.json").write_text(json.dumps({}))
        self.mod.HUB_DIR_ENV = str(hub_dir)
        prompt = self.mod.task_prompt(self._task())
        self.assertNotIn("U123STANDALONE", prompt)
        self.assertIn("unavailable", prompt)

    def test_no_owner_id_configured_anywhere_reports_unavailable(self):
        prompt = self.mod.task_prompt(self._task())
        self.assertIn("unavailable", prompt)
        self.assertNotIn("mcp__ld-tools__ld_slack_send", prompt)


class RunTaskSettingsEndToEndTests(unittest.TestCase):
    """Drives `qt -w <prompt>` as a real subprocess and inspects the exact
    argv/settings file run_task() builds for the claude launch."""

    def setUp(self):
        TMP_ROOT.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=str(TMP_ROOT))
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.qt_data = root / "qtdata"

        bin_dir = root / "bin"
        bin_dir.mkdir()
        _write_exec(bin_dir / "claude", FAKE_CLAUDE_ARGV)
        for name in ("osascript", "terminal-notifier"):
            _write_exec(bin_dir / name, FAKE_NOTIFIER_SHIM)
        self.assertNotIn("/T/", str(bin_dir))
        self.bin_dir = bin_dir
        self.argv_log = root / "argv.json"

    def _run_qt(self, prompt, extra_env=None):
        env = dict(os.environ)
        env["QT_DATA"] = str(self.qt_data)
        env["PATH"] = f"{self.bin_dir}:{env.get('PATH', '')}"
        env["FAKE_CLAUDE_ARGV_LOG"] = str(self.argv_log)
        env["FAKE_CLAUDE_JSON"] = json.dumps({"result": "ok", "session_id": "sess"})
        env["FAKE_CLAUDE_RC"] = "0"
        env.pop("QT_HUB", None)
        env.pop("QT_PERMISSIONS", None)
        env.pop("QT_ORIGIN", None)
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [sys.executable, str(QT_SCRIPT), "-w", prompt],
            capture_output=True, text=True, env=env, timeout=30,
        )

    def test_no_hub_configured_uses_qt_guard(self):
        proc = self._run_qt("a" * 20)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        captured = json.loads(self.argv_log.read_text())
        argv = captured["argv"]
        self.assertIn("--settings", argv)
        settings_path = argv[argv.index("--settings") + 1]
        self.assertTrue(settings_path.startswith(str(self.qt_data / "tmp")))

        self.assertIsNotNone(captured["settings_content"], "settings file was gone by the time claude ran")
        settings = json.loads(captured["settings_content"])
        hook = settings["hooks"]["PreToolUse"][0]
        self.assertEqual(hook["matcher"], "mcp__ld-tools__ld_slack_.*")
        self.assertIn("qt-guard.py", hook["hooks"][0]["command"])

        # run_task() removes the file in its `finally` right after the
        # claude subprocess returns.
        self.assertFalse(os.path.exists(settings_path), "settings file was not cleaned up")

    def test_hub_configured_uses_hub_guard(self):
        hub_dir = Path(self.tmp.name) / "hub"
        hub_dir.mkdir()
        (hub_dir / "guard.py").write_text("import sys\nsys.exit(0)\n")
        proc = self._run_qt("b" * 20, extra_env={"QT_HUB": str(hub_dir)})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        captured = json.loads(self.argv_log.read_text())
        settings = json.loads(captured["settings_content"])
        command = settings["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
        self.assertIn(str(hub_dir / "guard.py"), command)

    def test_settings_path_unique_across_two_runs(self):
        proc1 = self._run_qt("first task " + "x" * 20)
        self.assertEqual(proc1.returncode, 0, proc1.stderr)
        argv1 = json.loads(self.argv_log.read_text())["argv"]
        path1 = argv1[argv1.index("--settings") + 1]

        proc2 = self._run_qt("second task " + "y" * 20)
        self.assertEqual(proc2.returncode, 0, proc2.stderr)
        argv2 = json.loads(self.argv_log.read_text())["argv"]
        path2 = argv2[argv2.index("--settings") + 1]

        self.assertNotEqual(path1, path2)


class DoctorSlackGuardLineTests(unittest.TestCase):
    """`qt doctor`'s "Slack guard" line, driven as a real subprocess."""

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
        self.root = root

    def _doctor(self, config=None, hub_dir=None):
        if config is not None:
            with open(self.qt_data / "config.json", "w") as f:
                json.dump(config, f)
        env = dict(os.environ)
        env["QT_DATA"] = str(self.qt_data)
        env["PATH"] = f"{self.bin_dir}:{env.get('PATH', '')}"
        if hub_dir is not None:
            env["QT_HUB"] = str(hub_dir)
        else:
            env.pop("QT_HUB", None)
        return subprocess.run(
            [sys.executable, str(QT_SCRIPT), "doctor"],
            capture_output=True, text=True, env=env, timeout=30,
        )

    @staticmethod
    def _guard_line(stdout):
        for line in stdout.splitlines():
            if "Slack guard" in line:
                return line
        return None

    def test_no_owner_id_reports_deny_all(self):
        proc = self._doctor(config={})
        line = self._guard_line(proc.stdout)
        self.assertIsNotNone(line, proc.stdout)
        self.assertIn("qt-guard.py", line)
        self.assertIn("DENY-ALL", line)

    def test_owner_id_set_reports_owner_and_public_off(self):
        proc = self._doctor(config={"slack_owner_id": "U123"})
        line = self._guard_line(proc.stdout)
        self.assertIn("U123", line)
        self.assertIn("public posting: off", line)

    def test_public_channels_on_is_reported(self):
        proc = self._doctor(config={"slack_owner_id": "U123", "slack_allow_public_channels": True})
        line = self._guard_line(proc.stdout)
        self.assertIn("public posting: on", line)

    def test_hub_guard_reports_hub_source_and_hub_owner(self):
        hub_dir = self.root / "hub"
        hub_dir.mkdir()
        (hub_dir / "guard.py").write_text("# fake hub guard\n")
        (hub_dir / "pass-config.json").write_text(json.dumps({"owner_slack_id": "U999"}))
        proc = self._doctor(config={}, hub_dir=hub_dir)
        line = self._guard_line(proc.stdout)
        self.assertIsNotNone(line, proc.stdout)
        self.assertIn("hub", line)
        self.assertIn("U999", line)
        self.assertIn(str(hub_dir / "guard.py"), line)


if __name__ == "__main__":
    unittest.main()
