#!/usr/bin/env python3
"""`qt allow` / `qt denials` (the denial-ledger steering surface, added
2026-10-28) and the user allowlist's merge into per-run --settings.

End-to-end against the real `qt` script, subprocess-driven, with QT_DATA /
QT_ALLOW_FILE / QT_DENIALS_LOG pointed at a throwaway temp dir under this
repo's own tmp/ so nothing touches ~/.quicktasks -- the same convention
test_setup_defaults.py uses.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
QT_SCRIPT = REPO_ROOT / "qt"
TMP_ROOT = REPO_ROOT / "tmp"

READ_TOOL = "mcp__claude_ai_Slack__slack_search_users"
WRITE_TOOL = "mcp__claude_ai_Slack__slack_send_message"


class AllowDenialsTests(unittest.TestCase):
    def setUp(self):
        TMP_ROOT.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=str(TMP_ROOT))
        self.addCleanup(self.tmp.cleanup)
        self.qt_data = Path(self.tmp.name) / "qtdata"
        self.allow_file = self.qt_data / "allow.json"
        self.ledger = self.qt_data / "logs" / "denials.jsonl"

    def _run(self, *args):
        env = dict(os.environ)
        env["QT_DATA"] = str(self.qt_data)
        # Pin the override paths explicitly so a stray developer env can
        # never redirect the test at the real ~/.quicktasks.
        env["QT_ALLOW_FILE"] = str(self.allow_file)
        env["QT_DENIALS_LOG"] = str(self.ledger)
        return subprocess.run(
            [sys.executable, str(QT_SCRIPT), *args],
            capture_output=True, text=True, env=env, timeout=30,
        )

    def _write_ledger(self, rows):
        self.ledger.parent.mkdir(parents=True, exist_ok=True)
        with open(self.ledger, "w") as f:
            for r in rows:
                f.write(json.dumps(r) + "\n")

    # --- qt allow ---------------------------------------------------------

    def test_allow_writes_the_allowlist(self):
        r = self._run("allow", READ_TOOL)
        self.assertEqual(r.returncode, 0, r.stderr)
        data = json.loads(self.allow_file.read_text())
        self.assertEqual(data["allow"], [READ_TOOL])
        self.assertIn("allowed:", r.stdout)

    def test_allow_is_idempotent(self):
        self.assertEqual(self._run("allow", READ_TOOL).returncode, 0)
        r = self._run("allow", READ_TOOL)
        self.assertEqual(r.returncode, 0)
        self.assertIn("already allowed", r.stdout)
        data = json.loads(self.allow_file.read_text())
        self.assertEqual(data["allow"], [READ_TOOL])

    def test_allow_refuses_write_shaped_tools(self):
        r = self._run("allow", WRITE_TOOL)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("refusing", r.stderr + r.stdout)
        self.assertFalse(self.allow_file.exists())

    def test_allow_refuses_non_mcp_tools(self):
        # 2026-11-03 review: `qt allow Bash` would otherwise widen every
        # future run's permissions beyond the documented scope.
        r = self._run("allow", "Bash")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("refusing", r.stderr + r.stdout)
        self.assertFalse(self.allow_file.exists())

    def test_allow_tolerates_malformed_existing_file(self):
        self.qt_data.mkdir(parents=True, exist_ok=True)
        self.allow_file.write_text("not json {")
        r = self._run("allow", READ_TOOL)
        self.assertEqual(r.returncode, 0, r.stderr)
        data = json.loads(self.allow_file.read_text())
        self.assertEqual(data["allow"], [READ_TOOL])

    # --- qt denials --------------------------------------------------------

    def test_denials_reports_empty_without_a_ledger(self):
        r = self._run("denials")
        self.assertEqual(r.returncode, 0)
        self.assertIn("no denials recorded yet", r.stdout)

    def test_denials_ranks_by_count_and_shows_steering_hints(self):
        self._write_ledger([
            {"ts": "2026-10-28T07:53:00Z", "guard": "qt",
             "tool_name": READ_TOOL, "reason": "connectors off"},
            {"ts": "2026-10-28T08:36:00Z", "guard": "qt",
             "tool_name": READ_TOOL, "reason": "connectors off"},
            {"ts": "2026-10-28T08:36:10Z", "guard": "hub",
             "tool_name": "Write", "reason": "auto classifier denied"},
            {"malformed": True},  # no tool_name -> bucketed, never crashes
        ])
        r = self._run("denials")
        self.assertEqual(r.returncode, 0)
        self.assertIn("4 denials, 3 distinct tools", r.stdout)
        # The 2x tool ranks above the 1x tools.
        self.assertLess(r.stdout.index("2x"), r.stdout.index("1x"))
        self.assertIn("qt allow <tool>", r.stdout)
        self.assertIn("slack_allowed_channels", r.stdout)

    # --- allowlist merge into per-run settings -----------------------------

    def test_allowlist_merges_into_rendered_guard_settings(self):
        """render_slack_guard_settings is what a run's --settings file comes
        from; the user allowlist must ride along with the shipped read set,
        or `qt allow` would only affect guard-hook decisions, never the
        permissions.allow the classifier consults."""
        self.assertEqual(self._run("allow", READ_TOOL).returncode, 0)
        code = (
            "import sys\n"
            "from importlib.machinery import SourceFileLoader\n"
            "from importlib.util import spec_from_loader, module_from_spec\n"
            # qt has no .py extension, so spec_from_file_location alone
            # can't sniff a loader for it -- SourceFileLoader explicitly.
            f"loader = SourceFileLoader('qt', r{str(QT_SCRIPT)!r})\n"
            "spec = spec_from_loader('qt', loader)\n"
            "qt = module_from_spec(spec)\n"
            "loader.exec_module(qt)\n"
            "guard = qt.resolve_slack_guard_cmd()[0]\n"
            "if not guard: sys.exit('no guard script available')\n"
            "path = qt.render_slack_guard_settings('test-tid')\n"
            "import json; s = json.load(open(path))\n"
            "allow = s['permissions']['allow']\n"
            f"assert {READ_TOOL!r} in allow, allow\n"
            "assert 'Read' in allow  # shipped set survived the merge\n"
            "print('settings merge ok')\n"
        )
        env = dict(os.environ)
        env["QT_DATA"] = str(self.qt_data)
        env["QT_ALLOW_FILE"] = str(self.allow_file)
        r = subprocess.run([sys.executable, "-c", code],
                           capture_output=True, text=True, env=env, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("settings merge ok", r.stdout)


if __name__ == "__main__":
    unittest.main()
