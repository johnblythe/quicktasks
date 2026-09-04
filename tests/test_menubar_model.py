#!/usr/bin/env python3
"""Menu-bar widget: state reading, dedup, ordering, and the aggregate dot.

Follows this repo's existing test style (see test_hub_feed.py): drive the real
thing as a subprocess against throwaway fixture directories rather than
reimplementing its logic in the test. Here the real thing is the built
QuicktaskStatus binary invoked with `--dump-model`, which runs the same
Store/MenuModel code the menu draws from and prints the result as JSON. That
keeps the assertions on observable behaviour and means the tests cannot drift
away from what the widget actually shows.

The binary is built once per run by menubar/build.sh (swiftc only, no Xcode
project). If swiftc is missing the whole module skips rather than fails, so a
machine without the Command Line Tools can still run the Python suite.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MENUBAR_DIR = REPO_ROOT / "menubar"
BUILD_SCRIPT = MENUBAR_DIR / "build.sh"
BINARY = MENUBAR_DIR / "build" / "QuicktaskStatus.app" / "Contents" / "MacOS" / "QuicktaskStatus"

_BUILD_ERROR = None


def setUpModule():
    """Build the widget once, or record why we cannot."""
    global _BUILD_ERROR
    if sys.platform != "darwin":
        _BUILD_ERROR = "macOS only"
        return
    if shutil.which("swiftc") is None:
        _BUILD_ERROR = "swiftc not on PATH (xcode-select --install)"
        return
    proc = subprocess.run(
        ["bash", str(BUILD_SCRIPT), "--no-install"],
        capture_output=True, text=True, timeout=300,
    )
    if proc.returncode != 0 or not BINARY.is_file():
        _BUILD_ERROR = f"build failed: {proc.stdout}\n{proc.stderr}"


class ModelCase(unittest.TestCase):
    """Fixture helpers: write task/job JSON, then read back the menu model."""

    def setUp(self):
        if _BUILD_ERROR:
            self.skipTest(_BUILD_ERROR)
        self.tmp = Path(tempfile.mkdtemp(prefix="menubar-", dir=REPO_ROOT / "tmp"
                                         if (REPO_ROOT / "tmp").is_dir() else None))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.qt_data = self.tmp / "qtdata"
        self.hub = self.tmp / "hub"
        (self.qt_data / "tasks").mkdir(parents=True)
        (self.hub / "jobs").mkdir(parents=True)

    # --- fixture writers ---------------------------------------------------

    def write_task(self, tid, **fields):
        """One record in qt's ledger, ~/.quicktasks/tasks/<id>.json."""
        rec = {
            "id": tid,
            "prompt": fields.pop("prompt", f"prompt for {tid}"),
            "status": fields.pop("status", "done"),
            "created": fields.pop("created", "2026-09-01T10:00:00"),
            "invoked_from": "/tmp",
            "session_id": fields.pop("session_id", "sess-" + tid),
            "denials": fields.pop("denials", []),
        }
        for key in ("started", "finished", "result", "source"):
            if key in fields:
                rec[key] = fields.pop(key)
        rec.update(fields)
        (self.qt_data / "tasks" / f"{tid}.json").write_text(json.dumps(rec))

    def write_job(self, slug, **fields):
        """One record in hub's ledger, <hub>/jobs/<slug>/job.json."""
        jobdir = self.hub / "jobs" / slug
        jobdir.mkdir(parents=True, exist_ok=True)
        rec = {
            "item_id": fields.pop("item_id", slug),
            "title": fields.pop("title", f"title for {slug}"),
            "status": fields.pop("status", "done"),
            "started": fields.pop("started", "2026-09-01T10:00:00"),
            "home_state": "today",
            "session_id": fields.pop("session_id", "sess-" + slug),
        }
        for key in ("finished", "error", "denials", "rc"):
            if key in fields:
                rec[key] = fields.pop(key)
        rec.update(fields)
        (jobdir / "job.json").write_text(json.dumps(rec))

    # --- the thing under test ----------------------------------------------

    def model(self, hub=True, limit=50, extra_env=None):
        env = dict(os.environ)
        env["QT_DATA"] = str(self.qt_data)
        # Empty QT_HUB plus a fixture QT_DATA with no config.json is how the
        # widget sees "hub feed off", matching qt's resolve_hub_dir().
        env["QT_HUB"] = str(self.hub) if hub else ""
        env.update(extra_env or {})
        proc = subprocess.run(
            [str(BINARY), "--dump-model", "--limit", str(limit)],
            capture_output=True, text=True, timeout=60, env=env,
        )
        self.assertEqual(proc.returncode, 0, f"dump-model failed: {proc.stderr}")
        return json.loads(proc.stdout)

    def ids(self, model):
        return [r["id"] for r in model["records"]]

    def by_id(self, model, tid):
        for r in model["records"]:
            if r["id"] == tid:
                return r
        self.fail(f"{tid} not in model: {self.ids(model)}")


class TestEmptyAndAggregate(ModelCase):
    def test_empty_ledgers_read_as_idle(self):
        m = self.model()
        self.assertEqual(m["count"], 0)
        self.assertEqual(m["aggregate"], {"state": "idle", "count": 0})
        self.assertEqual(m["headline"], "All quiet")
        # An idle badge stays empty so the menu bar does not show a stray "0".
        self.assertEqual(m["badge"], "")
        self.assertIsNone(m["warning"])

    def test_running_task_drives_running_aggregate(self):
        self.write_task("t-run", status="running", started="2026-09-01T10:00:00")
        m = self.model()
        self.assertEqual(m["aggregate"], {"state": "running", "count": 1})
        self.assertEqual(m["badge"], "1")
        self.assertEqual(m["headline"], "1 task running")

    def test_blocked_and_failed_both_count_as_attention(self):
        self.write_task("t-block", status="blocked")
        self.write_task("t-fail", status="failed")
        self.write_task("t-timeout", status="timeout")
        self.write_task("t-ok", status="done")
        m = self.model()
        self.assertEqual(m["aggregate"], {"state": "attention", "count": 3})
        self.assertEqual(m["headline"], "3 tasks need you")

    def test_running_outranks_attention(self):
        """An in-flight run is the thing about to change, so it wins the dot."""
        self.write_task("t-block", status="blocked")
        self.write_task("t-run", status="running")
        m = self.model()
        self.assertEqual(m["aggregate"]["state"], "running")

    def test_queued_counts_as_active(self):
        self.write_task("t-q", status="queued")
        self.assertEqual(self.model()["aggregate"]["state"], "running")

    def test_done_only_is_idle(self):
        self.write_task("t-a", status="done")
        self.write_task("t-b", status="done")
        m = self.model()
        self.assertEqual(m["aggregate"]["state"], "idle")
        self.assertEqual(m["count"], 2)


class TestResumeAffordance(ModelCase):
    def test_blocked_with_session_wants_resume(self):
        self.write_task("t-block", status="blocked", session_id="abc",
                        denials=[{"tool_name": "Bash"}])
        r = self.by_id(self.model(), "t-block")
        self.assertTrue(r["can_resume"])
        self.assertTrue(r["wants_resume"])
        self.assertEqual(r["denials"], 1)

    def test_blocked_without_session_cannot_resume(self):
        """No session id means there is nothing to reopen; the row must not
        offer a click that would fail."""
        self.write_task("t-block", status="blocked", session_id="")
        r = self.by_id(self.model(), "t-block")
        self.assertFalse(r["can_resume"])
        self.assertFalse(r["wants_resume"])

    def test_done_task_is_resumable_but_not_flagged(self):
        self.write_task("t-done", status="done", session_id="abc")
        r = self.by_id(self.model(), "t-done")
        self.assertTrue(r["can_resume"])
        self.assertFalse(r["wants_resume"])


class TestDedup(ModelCase):
    def test_qt_task_and_its_hub_mirror_collapse(self):
        """qt's _feed_hub() writes item_id "qt-<task id>", so the hub copy of a
        quicktask must land on the same row as the ledger entry."""
        self.write_task("260904-090129-atlas", status="done",
                        finished="2026-09-04T09:05:38")
        self.write_job("qt-260904-090129-atlas-20260904-130538",
                       item_id="qt-260904-090129-atlas", status="done",
                       finished="2026-09-04T09:05:38")
        m = self.model()
        self.assertEqual(m["count"], 1, self.ids(m))
        # The surviving id is the one `qt resume` accepts.
        self.assertEqual(self.ids(m), ["260904-090129-atlas"])

    def test_hub_job_and_its_qt_mirror_collapse(self):
        """hub/run-job.sh registers the job *directory name* as a quicktask id,
        so the mirrored ledger row must land on the same row as the job."""
        slug = "pass-shortcut-20260903-145011-b80288"
        self.write_job(slug, item_id="pass-shortcut", status="done",
                       finished="2026-09-03T15:00:00")
        self.write_task(slug, status="done", source="pass",
                        finished="2026-09-03T15:00:00")
        m = self.model()
        self.assertEqual(m["count"], 1, self.ids(m))
        self.assertEqual(self.ids(m), [slug])
        self.assertEqual(self.by_id(m, slug)["origin"], "pass")

    def test_running_hub_job_appears_before_it_is_mirrored(self):
        """The whole reason both ledgers are read: a Pass job in flight is not
        in qt's ledger yet, and that is exactly the state worth showing."""
        self.write_job("pass-live-20260904-120000", item_id="pass-live",
                       status="running")
        m = self.model()
        self.assertEqual(m["count"], 1)
        self.assertEqual(m["aggregate"]["state"], "running")
        self.assertEqual(self.ids(m), ["pass-live-20260904-120000"])

    def test_finished_ledger_row_beats_stale_running_job_json(self):
        """The two writers land at different moments; whichever record has a
        finished timestamp is the later news."""
        self.write_task("260904-x", status="done", finished="2026-09-04T10:00:00")
        self.write_job("qt-260904-x-20260904-100000", item_id="qt-260904-x",
                       status="running")
        r = self.by_id(self.model(), "260904-x")
        self.assertEqual(r["status"], "done")
        self.assertEqual(self.model()["aggregate"]["state"], "idle")

    def test_finished_job_json_beats_stale_running_ledger_row(self):
        self.write_task("260904-y", status="running")
        self.write_job("qt-260904-y-20260904-100000", item_id="qt-260904-y",
                       status="failed", finished="2026-09-04T10:00:00")
        r = self.by_id(self.model(), "260904-y")
        self.assertEqual(r["status"], "failed")


class TestHubFeedOff(ModelCase):
    def test_hub_off_reads_only_the_qt_ledger(self):
        self.write_task("t-a", status="done")
        self.write_job("pass-live", item_id="pass-live", status="running")
        m = self.model(hub=False)
        self.assertIsNone(m["hub_jobs_dir"])
        self.assertEqual(self.ids(m), ["t-a"])
        self.assertEqual(m["aggregate"]["state"], "idle")

    def test_hub_dir_comes_from_config_json_when_env_is_unset(self):
        (self.qt_data / "config.json").write_text(json.dumps({"hub_dir": str(self.hub)}))
        self.write_job("pass-live", item_id="pass-live", status="running")
        m = self.model(hub=False)
        self.assertEqual(m["hub_jobs_dir"], str(self.hub / "jobs"))
        self.assertEqual(m["aggregate"]["state"], "running")


class TestOrderingAndTrimming(ModelCase):
    def test_active_rows_pin_above_finished_ones(self):
        self.write_task("t-old-run", status="running", started="2026-08-01T10:00:00")
        self.write_task("t-new-done", status="done", finished="2026-09-04T10:00:00")
        self.assertEqual(self.ids(self.model())[0], "t-old-run")

    def test_attention_rows_pin_above_finished_ones(self):
        """One-click resume is only one click if the blocked row is visible
        without scrolling past a week of successful runs."""
        for i in range(1, 5):
            self.write_task(f"t-done-{i}", status="done",
                            finished=f"2026-09-0{i}T10:00:00")
        self.write_task("t-blocked", status="blocked",
                        finished="2026-08-01T10:00:00")
        self.assertEqual(self.ids(self.model())[0], "t-blocked")

    def test_bands_order_active_then_attention_then_done(self):
        self.write_task("t-done", status="done", finished="2026-09-04T12:00:00")
        self.write_task("t-blocked", status="blocked", finished="2026-09-04T11:00:00")
        self.write_task("t-run", status="running", started="2026-09-04T10:00:00")
        self.assertEqual(self.ids(self.model()), ["t-run", "t-blocked", "t-done"])

    def test_attention_rows_survive_the_row_limit(self):
        for i in range(1, 6):
            self.write_task(f"t-done-{i}", status="done",
                            finished=f"2026-09-0{i}T10:00:00")
        self.write_task("t-blocked", status="blocked",
                        finished="2026-08-01T10:00:00")
        m = self.model(limit=2)
        self.assertIn("t-blocked", self.ids(m))

    def test_finished_rows_fall_in_newest_first_order(self):
        self.write_task("t-1", status="done", finished="2026-09-01T10:00:00")
        self.write_task("t-3", status="done", finished="2026-09-03T10:00:00")
        self.write_task("t-2", status="done", finished="2026-09-02T10:00:00")
        self.assertEqual(self.ids(self.model()), ["t-3", "t-2", "t-1"])

    def test_limit_trims_oldest_and_keeps_the_active_row(self):
        for i in range(6):
            self.write_task(f"t-{i}", status="done",
                            finished=f"2026-09-0{i + 1}T10:00:00")
        self.write_task("t-live", status="running", started="2026-08-01T09:00:00")
        m = self.model(limit=3)
        self.assertEqual(len(m["records"]), 3)
        self.assertIn("t-live", self.ids(m))
        # Aggregate is computed before trimming, so a running task that fell
        # off the visible list still colours the dot.
        self.assertEqual(m["aggregate"]["state"], "running")

    def test_aggregate_counts_every_task_not_just_visible_ones(self):
        for i in range(5):
            self.write_task(f"t-block-{i}", status="blocked",
                            finished=f"2026-09-0{i + 1}T10:00:00")
        m = self.model(limit=2)
        self.assertEqual(len(m["records"]), 2)
        self.assertEqual(m["aggregate"], {"state": "attention", "count": 5})


class TestRecordFields(ModelCase):
    def test_title_comes_from_the_prompt_and_is_trimmed_to_one_line(self):
        self.write_task("t-a", prompt="  first line\nsecond line  ")
        self.assertEqual(self.by_id(self.model(), "t-a")["title"],
                         "first line second line")

    def test_long_title_is_ellipsised_at_sixty_characters(self):
        self.write_task("t-a", prompt="x" * 200)
        title = self.by_id(self.model(), "t-a")["title"]
        self.assertEqual(len(title), 60)
        self.assertTrue(title.endswith("…"))

    def test_unknown_status_is_carried_through_not_guessed(self):
        """A status this build has never heard of must not read as done."""
        self.write_task("t-a", status="quantum")
        r = self.by_id(self.model(), "t-a")
        self.assertEqual(r["status"], "unknown")
        self.assertEqual(r["detail"], "Unknown")
        self.assertEqual(self.model()["aggregate"]["state"], "idle")

    def test_naive_local_timestamps_parse(self):
        """Both writers use datetime.isoformat(timespec="seconds"), which has
        no timezone; a parser that only accepts RFC 3339 would blank these."""
        self.write_task("t-a", status="done", started="2026-09-01T10:00:00",
                        finished="2026-09-01T10:04:00")
        r = self.by_id(self.model(), "t-a")
        self.assertIsNotNone(r["started"])
        self.assertIsNotNone(r["finished"])

    def test_qt_origin_defaults_to_quicktask_and_pass_is_tagged(self):
        self.write_task("t-qt", status="done")
        self.write_task("t-pass", status="done", source="pass")
        m = self.model()
        self.assertEqual(self.by_id(m, "t-qt")["origin"], "quicktask")
        self.assertEqual(self.by_id(m, "t-pass")["origin"], "pass")


class TestMalformedInput(ModelCase):
    def test_unparseable_json_is_skipped_not_fatal(self):
        (self.qt_data / "tasks" / "broken.json").write_text("{not json")
        self.write_task("t-good", status="done")
        m = self.model()
        self.assertEqual(self.ids(m), ["t-good"])

    def test_record_without_an_id_is_skipped(self):
        (self.qt_data / "tasks" / "nameless.json").write_text(json.dumps({"status": "done"}))
        self.write_task("t-good", status="done")
        self.assertEqual(self.ids(self.model()), ["t-good"])

    def test_job_directory_without_job_json_is_skipped(self):
        (self.hub / "jobs" / "half-made").mkdir()
        self.write_job("real-job", item_id="real-job", status="done")
        self.assertEqual(self.ids(self.model()), ["real-job"])

    def test_missing_ledger_directories_are_not_an_error(self):
        """qt not installed, or the hub checkout moved, should read as empty
        rather than as a warning row."""
        shutil.rmtree(self.qt_data / "tasks")
        shutil.rmtree(self.hub / "jobs")
        m = self.model()
        self.assertEqual(m["count"], 0)
        self.assertIsNone(m["warning"])

    def test_non_json_files_in_the_ledger_are_ignored(self):
        (self.qt_data / "tasks" / "notes.txt").write_text("scratch")
        self.write_task("t-good", status="done")
        self.assertEqual(self.ids(self.model()), ["t-good"])


class TestAgainstRealState(ModelCase):
    """One read-only pass over the machine's actual ledgers. Catches shape
    drift that fixtures cannot, and asserts only invariants that hold for any
    real state, so it stays green as John's history changes."""

    def test_real_ledgers_produce_a_coherent_model(self):
        real_qt = Path.home() / ".quicktasks" / "tasks"
        if not real_qt.is_dir():
            self.skipTest("no quicktasks ledger on this machine")
        env = dict(os.environ)
        env.pop("QT_DATA", None)
        env.pop("QT_HUB", None)
        proc = subprocess.run(
            [str(BINARY), "--dump-model", "--limit", "500"],
            capture_output=True, text=True, timeout=60, env=env,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        m = json.loads(proc.stdout)

        ids = [r["id"] for r in m["records"]]
        self.assertEqual(len(ids), len(set(ids)), "dedup left duplicate rows")
        self.assertEqual(m["count"], len(m["records"]))
        for r in m["records"]:
            self.assertTrue(r["id"], "record with an empty id")
            self.assertIn(r["origin"], ("quicktask", "pass"))
            self.assertIn(r["status"], [s.lower() for s in
                                        ("running", "queued", "blocked", "failed",
                                         "timeout", "done", "unknown")])
            # wants_resume implies can_resume, or the row offers a dead click.
            if r["wants_resume"]:
                self.assertTrue(r["can_resume"])
        # The aggregate must agree with the rows it was computed from.
        active = sum(1 for r in m["records"] if r["status"] in ("running", "queued"))
        attention = sum(1 for r in m["records"] if r["status"] in ("blocked", "failed", "timeout"))
        if active:
            self.assertEqual(m["aggregate"], {"state": "running", "count": active})
        elif attention:
            self.assertEqual(m["aggregate"], {"state": "attention", "count": attention})
        else:
            self.assertEqual(m["aggregate"]["state"], "idle")


if __name__ == "__main__":
    unittest.main()
