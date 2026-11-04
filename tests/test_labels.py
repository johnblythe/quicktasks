#!/usr/bin/env python3
"""Task labels (2026-10-29): the human-readable row title every surface
shows instead of the raw task id. short_label() is the instant heuristic
applied at queue time; _refine_label() is the one cheap Haiku call at
finish time; _hub_item/_hub_job_record prefer the label over the prompt
prefix.

Unit-level, driving the real qt module via SourceFileLoader (no .py
extension), mirroring test_slack_guard.py's _load_qt_module pattern. The
refinement path is tested with a fake `claude` binary on PATH, never the
real one.
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
TMP_ROOT = REPO_ROOT / "tmp"

# Same isolation as the other subprocess suites: the real menubar app and
# the developer's real ~/.quicktasks must never leak in.
os.environ["QT_NOTIFY_INBOX"] = "0"


def _load_qt():
    loader = importlib.machinery.SourceFileLoader("qt", str(QT_SCRIPT))
    spec = importlib.util.spec_from_loader("qt", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class ShortLabelTests(unittest.TestCase):
    def setUp(self):
        self.qt = _load_qt()

    def test_strips_boilerplate_prefixes(self):
        self.assertEqual(self.qt.short_label("send me a few options for a meeting time"),
                         "a few options for a meeting time")
        self.assertEqual(self.qt.short_label("please can you check the deploys"),
                         "check the deploys")

    def test_plain_prompt_survives(self):
        self.assertEqual(self.qt.short_label("draft the incident review"),
                         "draft the incident review")

    def test_seven_word_cap_and_ellipsis(self):
        label = self.qt.short_label("one two three four five six seven eight nine ten")
        self.assertEqual(label, "one two three four five six seven")
        # The ellipsis only fires when the 7-word label itself runs long.
        long_wordy = self.qt.short_label("supercalifragilistic " * 10)
        self.assertTrue(long_wordy.endswith("…"))
        self.assertLessEqual(len(long_wordy), 48)

    def test_empty_prompt(self):
        self.assertEqual(self.qt.short_label(""), "")
        self.assertEqual(self.qt.short_label("   \n  "), "")

    def test_whitespace_collapsed(self):
        self.assertEqual(self.qt.short_label("check   the\n\ndeploys"), "check the deploys")


class RefineLabelTests(unittest.TestCase):
    def setUp(self):
        TMP_ROOT.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=str(TMP_ROOT))
        self.addCleanup(self.tmp.cleanup)
        self.qt = _load_qt()
        # Isolate every module-global the label path touches.
        self.qt.QT_DATA = self.tmp.name
        self._env = dict(os.environ)
        self.addCleanup(self._restore_env)
        os.environ.pop("QT_LABEL_REFINE", None)
        os.environ.pop("QT_LABEL_MODEL", None)

    def _restore_env(self):
        os.environ.clear()
        os.environ.update(self._env)

    def _fake_claude(self, text):
        bin_dir = Path(self.tmp.name) / "bin"
        bin_dir.mkdir(exist_ok=True)
        fake = bin_dir / "claude"
        fake.write_text(f"#!/bin/sh\nprintf '%s\\n' {json.dumps(text)}\n")
        fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
        os.environ["PATH"] = f"{bin_dir}:{os.environ.get('PATH', '')}"
        return fake

    def test_refined_label_replaces_the_heuristic(self):
        self._fake_claude("Meeting time options")
        task = {"prompt": "send me a few options for a meeting time between now and EOW",
                "label": "a few options for a meeting time"}
        self.qt._refine_label(task)
        self.assertEqual(task["label"], "Meeting time options")
        self.assertTrue(task["label_refined"])

    def test_runs_once_per_task(self):
        self._fake_claude("Meeting time options")
        task = {"prompt": "x y z", "label": "x y z", "label_refined": True}
        self.qt._refine_label(task)
        self.assertEqual(task["label"], "x y z")  # untouched

    def test_junk_output_keeps_the_heuristic(self):
        self._fake_claude("")  # empty stdout fails the sanity check
        task = {"prompt": "check the deploys", "label": "check the deploys"}
        self.qt._refine_label(task)
        self.assertEqual(task["label"], "check the deploys")

    def test_no_claude_no_crash(self):
        os.environ["PATH"] = str(Path(self.tmp.name) / "bin")  # nothing in it
        (Path(self.tmp.name) / "bin").mkdir(exist_ok=True)
        task = {"prompt": "check the deploys", "label": "check the deploys"}
        self.qt._refine_label(task)  # must not raise
        self.assertEqual(task["label"], "check the deploys")

    def test_kill_switch(self):
        os.environ["QT_LABEL_REFINE"] = "0"
        self._fake_claude("Meeting time options")
        task = {"prompt": "x y z", "label": "x y z"}
        self.qt._refine_label(task)
        self.assertNotIn("label_refined", task)


class HubTitleTests(unittest.TestCase):
    def setUp(self):
        self.qt = _load_qt()

    def test_hub_item_prefers_the_label(self):
        item = self.qt._hub_item({"id": "t1", "prompt": "send me a long prompt " * 10,
                                  "label": "Meeting time options", "created": None})
        self.assertEqual(item["title"], "Meeting time options")
        self.assertEqual(item["quote"], "send me a long prompt " * 10)

    def test_hub_item_falls_back_to_prompt_prefix(self):
        item = self.qt._hub_item({"id": "t1", "prompt": "draft the review",
                                  "created": None})
        self.assertEqual(item["title"], "draft the review")

    def test_hub_job_record_prefers_the_label(self):
        job, body = self.qt._hub_job_record(
            {"id": "t1", "prompt": "send me a thing please", "label": "The thing",
             "status": "done", "result": "ok", "created": "2026-10-29T09:00:00"},
            "qt-t1", 0)
        self.assertEqual(job["title"], "The thing")
        self.assertEqual(body, "ok")


if __name__ == "__main__":
    unittest.main()
