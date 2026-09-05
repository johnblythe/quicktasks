#!/usr/bin/env python3
"""Menu-bar widget: the two feeds, dedup, sections, ordering, and payloads.

Follows this repo's existing test style (see test_hub_feed.py): drive the real
thing as a subprocess against throwaway fixture directories rather than
reimplementing its logic in the test. Here the real thing is the built
QuicktaskStatus binary invoked with `--dump-model`, which runs the same
Feed/Store/MenuModel code the menu draws from and prints the result as JSON.
That keeps the assertions on observable behaviour and means the tests cannot
drift away from what the widget actually shows.

The other seams get the same treatment. `--dump-capture`, `--dump-run`, and
`--dump-decision` print the POST bodies the widget would send without sending
them, because payload construction is the part of an HTTP client most worth
pinning down and the part least worth a live server to check. `--dump-endpoint`
prints where the widget would look for The Pass without making a request, which
is the only way to test discovery without depending on what is really listening
on 8811. `--dump-keys` walks the keyboard highlight over the visible rows, so
the keyboard is tested without a display. And FixturePass stands up a real
loopback server on an ephemeral port, so the /status.json path is exercised end
to end -- transport, parse, join, merge -- and so is the fallback when nothing
answers, and so is the one seam that really posts (`--post-run`, whose 409 is
an expected answer rather than a fault).

Every file-feed case sets QT_PASS_URL="" so it stays deterministic on a machine
where the real Pass happens to be up on 8811.

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
import threading
import unittest
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
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
        # Empty QT_PASS_URL pins the widget to the file ledgers. Without it
        # every file-feed assertion here would depend on whether John's Pass
        # happens to be serving on 8811 right now.
        env["QT_PASS_URL"] = ""
        # Keep the read-back of the login toggle away from the real
        # LaunchAgents directory; nothing in this suite ever writes it.
        env["QT_MENUBAR_AGENT_PLIST"] = str(self.tmp / "agents" / "never-written.plist")
        env.update(extra_env or {})
        proc = subprocess.run(
            [str(BINARY), "--dump-model", "--limit", str(limit)],
            capture_output=True, text=True, timeout=60, env=env,
        )
        self.assertEqual(proc.returncode, 0, f"dump-model failed: {proc.stderr}")
        return json.loads(proc.stdout)

    def run_binary(self, *args, extra_env=None, expect=0):
        """One-off invocation for the payload and login-item seams."""
        env = dict(os.environ)
        env["QT_DATA"] = str(self.qt_data)
        env["QT_HUB"] = str(self.hub)
        env["QT_PASS_URL"] = ""
        env["QT_MENUBAR_AGENT_PLIST"] = str(self.tmp / "agents" / "never-written.plist")
        env.update(extra_env or {})
        proc = subprocess.run([str(BINARY), *args], capture_output=True, text=True,
                              timeout=60, env=env)
        self.assertEqual(proc.returncode, expect,
                         f"{args} exited {proc.returncode}: {proc.stderr}")
        return proc

    def endpoint(self, extra_env=None):
        """`--dump-endpoint` with QT_PASS_URL *absent*, so the rest of the
        discovery order is actually reachable. Makes no request, which is the
        point: a discovery test must not depend on what is really listening on
        8811, and must never poll John's live Pass."""
        env = dict(os.environ)
        env.pop("QT_PASS_URL", None)
        env["QT_DATA"] = str(self.qt_data)
        env["QT_HUB"] = str(self.hub)
        env["QT_MENUBAR_AGENT_PLIST"] = str(self.tmp / "agents" / "never-written.plist")
        env.update(extra_env or {})
        proc = subprocess.run([str(BINARY), "--dump-endpoint"], capture_output=True,
                              text=True, timeout=60, env=env)
        self.assertEqual(proc.returncode, 0, f"dump-endpoint failed: {proc.stderr}")
        return json.loads(proc.stdout)

    def write_pass_url(self, text):
        """What serve.py drops at <hub>/.pass-url when it binds a port."""
        (self.hub / ".pass-url").write_text(text)

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
        # File feed only: a live Pass on this machine would make the run
        # non-deterministic, and TestPassFeed covers that path with a fixture.
        env["QT_PASS_URL"] = ""
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


# --- The Pass feed -----------------------------------------------------------


def _iso(dt):
    """What both writers emit: local time, no zone, second resolution."""
    return dt.isoformat(timespec="seconds")


def job(item_id, **fields):
    """One /status.json jobs[] entry, with the contract's full key set."""
    rec = {
        "item_id": item_id,
        "title": fields.pop("title", f"title for {item_id}"),
        "state": fields.pop("state", "running"),
        "status": fields.pop("status", "running"),
        "started": fields.pop("started", _iso(datetime.now() - timedelta(minutes=2))),
        "elapsed_s": fields.pop("elapsed_s", 120),
        "failed": fields.pop("failed", False),
        "blocked": fields.pop("blocked", False),
        "session_id": fields.pop("session_id", "sess-" + item_id),
        "resume_url": fields.pop("resume_url", None),
        "report": fields.pop("report", None),
        "outputs": fields.pop("outputs", []),
    }
    rec.update(fields)
    return rec


def need(item_id, reason, **fields):
    """One /status.json needs_you[] entry, in its v1 shape: no resume_url and
    no report, which is why the widget joins these onto jobs[] by item_id.
    v2 fields (resume_url, report, session_id, started, can_run) are passed
    through when a caller wants them, so the same helper covers both."""
    rec = {
        "item_id": item_id,
        "title": fields.pop("title", f"title for {item_id}"),
        "state": fields.pop("state", reason),
        "reason": reason,
    }
    rec.update(fields)
    return rec


def status_fixture(jobs=(), needs=(), groups=None, counts=None, pass_url=None,
                   item_url_template=None):
    payload = {
        "generated_at": _iso(datetime.now()),
        "groups": groups if groups is not None else [
            {"key": "gate", "label": "Needs your go", "count": 2, "undone": 1},
        ],
        "counts": counts if counts is not None else {
            "running": 0, "verify": 0, "gate": 0, "blocked": 0, "failed": 0,
        },
        "jobs": list(jobs),
        "needs_you": list(needs),
    }
    if pass_url is not None:
        payload["pass_url"] = pass_url
    if item_url_template is not None:
        payload["item_url_template"] = item_url_template
    return payload


class _Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    @property
    def owner(self):
        return self.server.owner

    def do_GET(self):
        self.owner.gets.append({"path": self.path, "headers": dict(self.headers)})
        if self.path != "/status.json":
            return self.send_error(404)
        body = self.owner.status_bytes()
        self.send_response(self.owner.status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        try:
            parsed = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            parsed = None
        self.owner.posts.append({"path": self.path, "body": parsed,
                                 "headers": dict(self.headers)})
        code = self.owner.post_codes.get(self.path, self.owner.post_code)
        # A route this Pass does not have answers 404 with a plain-text body,
        # the way BaseHTTPRequestHandler's own send_error would.
        if code == 404:
            return self.send_error(404)
        # serve.py answers a refused POST with plain text, not JSON: /run's 409
        # body is literally "already running" or "max concurrent jobs running".
        if self.owner.post_text is not None:
            body = self.owner.post_text.encode()
            ctype = "text/plain; charset=utf-8"
        else:
            body = json.dumps(self.owner.post_body).encode()
            ctype = "application/json"
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class FixturePass:
    """A real HTTP server on an ephemeral loopback port, standing in for
    hub/serve.py. Real rather than mocked because the widget's Pass path is a
    URLSession round trip, and the thing most worth proving is that the round
    trip works and that its absence is handled."""

    def __init__(self, payload=None, raw=None, status_code=200,
                 post_body=None, post_code=200, post_text=None,
                 post_codes=None):
        self.payload = payload
        self.raw = raw
        self.status_code = status_code
        self.post_body = post_body if post_body is not None else {"ok": True, "id": "cap-1"}
        self.post_code = post_code
        self.post_text = post_text
        # Per-path status codes, keyed by path ("/decide"). This is how a Pass
        # that has not shipped a route yet is modelled: the route 404s while
        # every other POST still works, which is exactly the shape the widget
        # feature-detects against. Falls back to post_code for any path not
        # named here.
        self.post_codes = dict(post_codes or {})
        self.gets = []
        self.posts = []
        self._srv = None

    def posts_to(self, path):
        return [p for p in self.posts if p["path"] == path]

    def status_bytes(self):
        if self.raw is not None:
            return self.raw.encode() if isinstance(self.raw, str) else self.raw
        return json.dumps(self.payload or {}).encode()

    def start(self):
        self._srv = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        self._srv.owner = self
        threading.Thread(target=self._srv.serve_forever, daemon=True).start()
        return f"http://127.0.0.1:{self._srv.server_address[1]}"

    def stop(self):
        if self._srv is not None:
            self._srv.shutdown()
            self._srv.server_close()
            self._srv = None


class PassCase(ModelCase):
    """Adds a fixture Pass and a model() that reads from it."""

    def serve(self, **kwargs):
        server = FixturePass(**kwargs)
        base = server.start()
        self.addCleanup(server.stop)
        self.server = server
        return base

    def pass_model(self, base, hub=False, limit=50):
        return self.model(hub=hub, limit=limit, extra_env={"QT_PASS_URL": base})

    def section(self, model, key):
        for s in model["sections"]:
            if s["key"] == key:
                return s
        self.fail(f"no {key} section in {[s['key'] for s in model['sections']]}")


class TestPassFeed(PassCase):
    def test_status_json_becomes_the_model(self):
        base = self.serve(payload=status_fixture(
            jobs=[job("alpha", status="running")],
            counts={"running": 1, "verify": 0, "gate": 0, "blocked": 0, "failed": 0}))
        m = self.pass_model(base)
        self.assertEqual(m["source"], "pass")
        self.assertTrue(m["pass_reachable"])
        self.assertIsNone(m["pass_error"])
        self.assertEqual(m["count"], 1)
        self.assertEqual(self.ids(m), ["alpha"])
        # pass_url is absent from this fixture, so the widget keeps the URL it
        # was configured with rather than inventing one.
        self.assertEqual(m["pass_url"], base)

    def test_pass_url_from_the_payload_wins(self):
        """The Pass walks 8811..8820 looking for a free port, so its own idea
        of where it lives is the one report links have to hang off."""
        base = self.serve(payload=status_fixture(
            jobs=[job("alpha", report="/job/alpha/output/report.html")],
            pass_url="http://localhost:8899"))
        m = self.pass_model(base)
        self.assertEqual(m["pass_url"], "http://localhost:8899")
        self.assertEqual(self.by_id(m, "alpha")["report_url"],
                         "http://localhost:8899/job/alpha/output/report.html")

    def test_needs_you_orders_verify_gate_blocked_failed(self):
        base = self.serve(payload=status_fixture(
            jobs=[job("j-fail", status="failed", failed=True),
                  job("j-block", status="running", blocked=True),
                  job("j-verify", status="done")],
            needs=[need("j-fail", "failed"), need("g-gate", "gate"),
                   need("j-block", "blocked"), need("j-verify", "verify")]))
        m = self.pass_model(base)
        # Payload order is deliberately scrambled; the widget's order is not.
        self.assertEqual(self.section(m, "needs_you")["ids"],
                         ["j-verify", "g-gate", "j-block", "j-fail"])
        self.assertEqual([r["reason"] for r in m["records"]
                          if r["section"] == "needs_you"],
                         ["verify", "gate", "blocked", "failed"])

    def test_gate_item_with_no_job_still_gets_a_row(self):
        """A gate item has no job, no session, and no status -- the reason is
        the only thing the row can say, so it has to be able to say it."""
        base = self.serve(payload=status_fixture(
            needs=[need("gate-item-1", "gate")]))
        r = self.by_id(self.pass_model(base), "gate-item-1")
        self.assertEqual(r["reason"], "gate")
        self.assertEqual(r["detail"], "Needs go")
        self.assertEqual(r["section"], "needs_you")
        self.assertEqual(r["status"], "unknown")
        self.assertFalse(r["can_resume"])
        self.assertFalse(r["can_decide"])

    def test_verify_row_carries_a_verdict_and_a_report(self):
        base = self.serve(payload=status_fixture(
            jobs=[job("ld188", status="done", state="verify",
                      report="/job/ld188/output/report.html",
                      outputs=["RESULT.md", "report.html"],
                      resume_url="quicktask://resume/ld188-20260904-101500-a1b2c3")],
            needs=[need("ld188", "verify", state="verify")]))
        r = self.by_id(self.pass_model(base), "ld188-20260904-101500-a1b2c3")
        self.assertTrue(r["can_decide"], "a verify row must offer accept/redo/reject")
        self.assertEqual(r["item_id"], "ld188")
        self.assertEqual(r["state"], "verify")
        self.assertEqual(r["detail"], "Verify")
        self.assertEqual(r["report"], "/job/ld188/output/report.html")
        self.assertEqual(r["report_url"], base + "/job/ld188/output/report.html")
        self.assertEqual(r["outputs"], 2)

    def test_only_verify_rows_can_decide(self):
        base = self.serve(payload=status_fixture(
            jobs=[job("j-block", blocked=True)],
            needs=[need("j-block", "blocked"), need("g", "gate")]))
        m = self.pass_model(base)
        self.assertFalse(any(r["can_decide"] for r in m["records"]))

    def test_resume_url_slug_is_the_row_id(self):
        """The slug in the URL is what `qt resume` accepts, so it is the
        identity the widget carries -- the item id is kept alongside for the
        decisions payload, which is keyed the other way."""
        base = self.serve(payload=status_fixture(
            jobs=[job("shepherd-app", blocked=True,
                      resume_url="quicktask://resume/shepherd-app-20260904-081500-ddeeff")],
            needs=[need("shepherd-app", "blocked")]))
        r = self.by_id(self.pass_model(base), "shepherd-app-20260904-081500-ddeeff")
        self.assertEqual(r["item_id"], "shepherd-app")
        self.assertEqual(r["resume_url"],
                         "quicktask://resume/shepherd-app-20260904-081500-ddeeff")
        self.assertTrue(r["can_resume"])
        self.assertTrue(r["wants_resume"])

    def test_job_booleans_outrank_the_status_string(self):
        """runner.py can leave status "done" on a run that failed, and the
        widget must not show that row as green."""
        base = self.serve(payload=status_fixture(
            jobs=[job("j-a", status="done", failed=True),
                  job("j-b", status="done", blocked=True)]))
        m = self.pass_model(base)
        self.assertEqual(self.by_id(m, "j-a")["status"], "failed")
        self.assertEqual(self.by_id(m, "j-b")["status"], "blocked")

    def test_failed_job_missing_from_needs_you_still_lands_there(self):
        """A dead run must never sit in the quiet tail, even if the server
        forgot to list it."""
        base = self.serve(payload=status_fixture(
            jobs=[job("j-dead", status="failed", failed=True)], needs=[]))
        r = self.by_id(self.pass_model(base), "j-dead")
        self.assertEqual(r["section"], "needs_you")
        self.assertEqual(r["reason"], "failed")

    def test_running_rows_land_in_running_with_an_elapsed_baseline(self):
        base = self.serve(payload=status_fixture(
            jobs=[job("j-live", status="running", elapsed_s=252)]))
        r = self.by_id(self.pass_model(base), "j-live")
        self.assertEqual(r["section"], "running")
        self.assertEqual(r["elapsed_s"], 252)
        self.assertIsNotNone(r["started"])

    def test_finished_time_is_reconstructed_from_started_plus_elapsed(self):
        """The contract carries no `finished`, so today-vs-earlier has to be
        derived. A job that started two hours ago and ran eight minutes
        finished today."""
        base = self.serve(payload=status_fixture(
            jobs=[job("j-done", status="done", state="today", elapsed_s=480,
                      started=_iso(datetime.now() - timedelta(hours=2)))]))
        r = self.by_id(self.pass_model(base), "j-done")
        self.assertEqual(r["section"], "done_today")
        self.assertIsNotNone(r["finished"])

    def test_groups_and_aggregate_come_through(self):
        base = self.serve(payload=status_fixture(
            jobs=[job("j-live", status="running")],
            groups=[{"key": "gate", "label": "Needs your go", "count": 4, "undone": 2},
                    {"key": "today", "label": "Today", "count": 9, "undone": 5}]))
        m = self.pass_model(base)
        self.assertEqual([g["key"] for g in m["groups"]], ["gate", "today"])
        self.assertEqual(m["groups"][0]["undone"], 2)
        self.assertEqual(m["aggregate"], {"state": "running", "count": 1})

    def test_needs_you_beats_running_in_the_aggregate_only_when_nothing_runs(self):
        base = self.serve(payload=status_fixture(
            jobs=[job("j-live", status="running")],
            needs=[need("g", "gate")]))
        self.assertEqual(self.pass_model(base)["aggregate"]["state"], "running")

    def test_gate_only_reads_as_attention(self):
        base = self.serve(payload=status_fixture(needs=[need("g", "gate")]))
        m = self.pass_model(base)
        self.assertEqual(m["aggregate"], {"state": "attention", "count": 1})
        self.assertEqual(m["headline"], "1 task needs you")

    def test_duplicate_needs_you_entries_collapse(self):
        base = self.serve(payload=status_fixture(
            needs=[need("g", "gate"), need("g", "verify")]))
        m = self.pass_model(base)
        self.assertEqual(m["count"], 1)
        self.assertEqual(self.by_id(m, "g")["reason"], "gate")

    def test_the_client_sends_no_origin_header(self):
        """serve.py's _origin_blocked() lets a request through only when Origin
        is absent or same-origin, and a native app's absence of one is the hole
        it is meant to come in by. Asserted on the GET the poll makes, from the
        same URLSession the POSTs use."""
        base = self.serve(payload=status_fixture(jobs=[job("alpha")]))
        self.pass_model(base)
        self.assertTrue(self.server.gets, "the widget never polled")
        for request in self.server.gets:
            self.assertNotIn("Origin", request["headers"])


class TestPassFallback(PassCase):
    def test_unreachable_pass_falls_back_to_the_files(self):
        self.write_task("t-local", status="done")
        # Port 1 on loopback: nothing listens there and the refusal is instant.
        m = self.model(extra_env={"QT_PASS_URL": "http://127.0.0.1:1"})
        self.assertEqual(m["source"], "files")
        self.assertFalse(m["pass_reachable"])
        self.assertIsNotNone(m["pass_error"])
        self.assertEqual(self.ids(m), ["t-local"])

    def test_fallback_still_reads_the_hub_job_files(self):
        """The file feed is the whole v1 model, not a degraded slice of it."""
        self.write_job("pass-live-20260904-120000", item_id="pass-live",
                       status="running")
        m = self.model(extra_env={"QT_PASS_URL": "http://127.0.0.1:1"})
        self.assertEqual(m["source"], "files")
        self.assertEqual(self.ids(m), ["pass-live-20260904-120000"])
        self.assertEqual(m["aggregate"]["state"], "running")

    def test_malformed_status_json_falls_back(self):
        self.write_task("t-local", status="done")
        base = self.serve(raw="{not json")
        m = self.pass_model(base)
        self.assertEqual(m["source"], "files")
        self.assertEqual(self.ids(m), ["t-local"])

    def test_http_error_falls_back(self):
        self.write_task("t-local", status="done")
        base = self.serve(payload=status_fixture(), status_code=500)
        m = self.pass_model(base)
        self.assertEqual(m["source"], "files")
        self.assertIn("500", m["pass_error"])

    def test_json_that_is_not_a_status_payload_falls_back(self):
        """Something else answering on the port must not read as an empty
        Pass, which would hide every gate and verify row behind "all quiet"."""
        self.write_task("t-local", status="blocked")
        base = self.serve(payload={"hello": "world"})
        m = self.pass_model(base)
        self.assertEqual(m["source"], "files")
        self.assertIsNotNone(m["pass_error"])
        self.assertEqual(self.ids(m), ["t-local"])

    def test_an_empty_but_valid_status_payload_is_not_a_fallback(self):
        base = self.serve(payload=status_fixture(jobs=[], needs=[]))
        m = self.pass_model(base)
        self.assertEqual(m["source"], "pass")
        self.assertEqual(m["count"], 0)
        self.assertEqual(m["headline"], "All quiet")

    def test_empty_pass_url_pins_the_widget_to_the_files(self):
        self.write_task("t-local", status="done")
        m = self.model(extra_env={"QT_PASS_URL": ""})
        self.assertEqual(m["source"], "files")
        self.assertIsNone(m["pass_error"])


class TestPassMerge(PassCase):
    def test_a_freshly_fired_quicktask_shows_while_the_pass_cannot_see_it(self):
        """A task fired with qt (or with quick-fire) does not reach The Pass
        until it finishes. "I just fired that and it is not in the list" is
        where the widget would lose trust, so the qt ledger is read in Pass
        mode too."""
        self.write_task("260904-114500-fresh", status="running",
                        started=_iso(datetime.now()))
        base = self.serve(payload=status_fixture(jobs=[job("alpha")]))
        m = self.pass_model(base)
        self.assertEqual(m["source"], "pass")
        self.assertIn("260904-114500-fresh", self.ids(m))
        self.assertEqual(self.by_id(m, "260904-114500-fresh")["section"], "running")

    def test_pass_row_and_qt_ledger_row_collapse_on_the_resume_slug(self):
        self.write_task("260904-090129-atlas", status="running",
                        session_id="sess-ledger")
        base = self.serve(payload=status_fixture(
            jobs=[job("qt-260904-090129-atlas", status="running",
                      resume_url="quicktask://resume/260904-090129-atlas")]))
        m = self.pass_model(base)
        self.assertEqual(m["count"], 1, self.ids(m))
        r = self.by_id(m, "260904-090129-atlas")
        self.assertEqual(r["item_id"], "qt-260904-090129-atlas")

    def test_qt_prefixed_item_id_collapses_without_a_resume_url(self):
        self.write_task("260904-x", status="running")
        base = self.serve(payload=status_fixture(
            jobs=[job("qt-260904-x", status="running", resume_url=None)]))
        m = self.pass_model(base)
        self.assertEqual(self.ids(m), ["260904-x"])
        self.assertEqual(self.by_id(m, "260904-x")["origin"], "quicktask")

    def test_finished_ledger_row_beats_a_stale_running_pass_row(self):
        """The two are written at different moments and either can be stale."""
        self.write_task("260904-y", status="done",
                        finished=_iso(datetime.now() - timedelta(minutes=5)),
                        denials=[{"tool_name": "Bash"}])
        base = self.serve(payload=status_fixture(
            jobs=[job("qt-260904-y", status="running", resume_url=None)]))
        r = self.by_id(self.pass_model(base), "260904-y")
        self.assertEqual(r["status"], "done")
        self.assertEqual(r["section"], "done_today")
        # Detail the Pass does not carry survives the merge.
        self.assertEqual(r["denials"], 1)

    def test_a_pending_verdict_survives_a_finished_ledger_row(self):
        """A job whose ledger row says done is exactly the job The Pass is
        asking John to verify, so the verdict has to outlive the status."""
        self.write_task("260904-z", status="done",
                        finished=_iso(datetime.now() - timedelta(minutes=5)))
        base = self.serve(payload=status_fixture(
            jobs=[job("qt-260904-z", status="done", state="verify")],
            needs=[need("qt-260904-z", "verify", state="verify")]))
        r = self.by_id(self.pass_model(base), "260904-z")
        self.assertEqual(r["reason"], "verify")
        self.assertEqual(r["section"], "needs_you")
        self.assertTrue(r["can_decide"])

    def test_hub_job_files_are_not_read_in_pass_mode(self):
        """/status.json already covers jobs/, and reading both would give two
        answers for the same run."""
        self.write_job("pass-live-20260904-120000", item_id="pass-live",
                       status="running")
        base = self.serve(payload=status_fixture(jobs=[]))
        m = self.pass_model(base, hub=True)
        self.assertEqual(m["source"], "pass")
        self.assertEqual(m["count"], 0, self.ids(m))


class TestRequestPayloads(ModelCase):
    """The two POST bodies, built without sending them."""

    def payload(self, *args, **kwargs):
        return json.loads(self.run_binary(*args, **kwargs).stdout)

    def write_decisions(self, decisions, saved_at="2026-09-04T10:00:00.000Z"):
        (self.hub / "decisions.json").write_text(
            json.dumps({"saved_at": saved_at, "decisions": decisions}))

    def test_capture_payload_is_text_plus_source(self):
        body = self.payload("--dump-capture", "  call dan about the dates  ")
        self.assertEqual(body, {"text": "call dan about the dates",
                                "source": "menubar"})

    def test_capture_refuses_empty_text(self):
        self.run_binary("--dump-capture", "   ", expect=1)

    def test_decision_payload_matches_the_review_page(self):
        """Same five keys per decision the page's #save handler posts, and the
        same saved_at stamp shape."""
        body = self.payload("--dump-decision", "ld188-preview-smoke", "accept")
        self.assertEqual(sorted(body), ["decisions", "saved_at"])
        self.assertRegex(body["saved_at"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z$")
        self.assertEqual(len(body["decisions"]), 1)
        decision = body["decisions"][0]
        self.assertEqual(sorted(decision), ["action", "comment", "id", "state", "title"])
        self.assertEqual(decision["id"], "ld188-preview-smoke")
        self.assertEqual(decision["action"], "accept")
        self.assertEqual(decision["comment"], "")
        self.assertEqual(decision["state"], "verify")

    def test_redo_carries_the_note_as_comment(self):
        body = self.payload("--dump-decision", "ld188", "redo", "tighten the summary")
        self.assertEqual(body["decisions"][0]["action"], "redo")
        self.assertEqual(body["decisions"][0]["comment"], "tighten the summary")

    def test_reject_is_a_verdict_too(self):
        body = self.payload("--dump-decision", "ld188", "reject")
        self.assertEqual(body["decisions"][0]["action"], "reject")

    def test_only_accept_redo_reject_are_postable(self):
        """serve.py validates nothing, so this is the only thing between a typo
        and a junk row in decisions.json."""
        for action in ("drop", "go", "keep", ""):
            self.run_binary("--dump-decision", "ld188", action, expect=1)

    def test_decision_refuses_an_empty_item_id(self):
        self.run_binary("--dump-decision", "", "accept", expect=1)

    def test_pending_decisions_ride_along(self):
        """serve.py overwrites decisions.json wholesale on every save, so a
        one-row post from the menu bar would otherwise discard a review John
        saved in the browser and has not reconciled yet."""
        self.write_decisions([
            {"id": "other-item", "title": "Other", "state": "today",
             "action": "snooze", "comment": ""},
        ])
        body = self.payload("--dump-decision", "ld188", "accept")
        self.assertEqual([d["id"] for d in body["decisions"]],
                         ["other-item", "ld188"])
        self.assertEqual(body["decisions"][0]["action"], "snooze")

    def test_a_pending_decision_for_the_same_item_is_replaced(self):
        self.write_decisions([
            {"id": "ld188", "title": "LD-188", "state": "verify",
             "action": "redo", "comment": "old note"},
        ])
        body = self.payload("--dump-decision", "ld188", "accept")
        self.assertEqual(len(body["decisions"]), 1)
        self.assertEqual(body["decisions"][0]["action"], "accept")

    def test_a_reconciled_decisions_file_adds_nothing(self):
        """reconcile.py resets the file to an empty list when it is done."""
        self.write_decisions([], saved_at="")
        body = self.payload("--dump-decision", "ld188", "accept")
        self.assertEqual(len(body["decisions"]), 1)

    def test_a_broken_decisions_file_is_not_fatal(self):
        (self.hub / "decisions.json").write_text("{not json")
        body = self.payload("--dump-decision", "ld188", "accept")
        self.assertEqual([d["id"] for d in body["decisions"]], ["ld188"])

    def test_the_decision_uses_the_rows_own_title_and_state(self):
        """The page echoes the item's title and state back; so does this."""
        self.write_job("ld188-20260904-101500", item_id="ld188",
                       title="Draft Q3 roadmap summary", status="done")
        body = self.payload("--dump-decision", "ld188", "accept")
        decision = body["decisions"][0]
        self.assertEqual(decision["title"], "Draft Q3 roadmap summary")


class TestLoginItemReadback(ModelCase):
    """Read-back only. Nothing here writes a LaunchAgent or calls launchctl."""

    def test_login_item_reads_false_without_a_plist(self):
        self.assertFalse(self.model()["login_item"])

    def test_login_item_reads_true_when_the_plist_exists(self):
        plist = self.tmp / "agents" / "com.quicktasks.menubar.plist"
        plist.parent.mkdir(parents=True, exist_ok=True)
        plist.write_text("<plist/>")
        m = self.model(extra_env={"QT_MENUBAR_AGENT_PLIST": str(plist)})
        self.assertTrue(m["login_item"])


class TestSectionsFromFiles(ModelCase):
    """The file feed has no reason field, so the sections have to mean the same
    thing derived from a status as they do handed over by The Pass."""

    def test_blocked_and_failed_file_rows_land_in_needs_you(self):
        self.write_task("t-block", status="blocked")
        self.write_task("t-fail", status="failed")
        self.write_task("t-timeout", status="timeout")
        m = self.model()
        self.assertEqual(len(self.section_ids(m, "needs_you")), 3)
        self.assertEqual(self.by_id(m, "t-timeout")["detail"], "Timed out")

    def test_today_and_earlier_split_on_the_day(self):
        self.write_task("t-today", status="done",
                        finished=_iso(datetime.now() - timedelta(minutes=30)))
        self.write_task("t-old", status="done", finished="2026-01-02T10:00:00")
        m = self.model()
        self.assertEqual(self.section_ids(m, "done_today"), ["t-today"])
        self.assertEqual(self.section_ids(m, "earlier"), ["t-old"])

    def test_sections_come_out_in_reading_order(self):
        self.write_task("t-run", status="running")
        self.write_task("t-block", status="blocked")
        self.write_task("t-today", status="done",
                        finished=_iso(datetime.now() - timedelta(minutes=5)))
        self.write_task("t-old", status="done", finished="2026-01-02T10:00:00")
        m = self.model()
        self.assertEqual([s["key"] for s in m["sections"]],
                         ["running", "needs_you", "done_today", "earlier"])

    def test_only_earlier_starts_collapsed(self):
        """The two sections that carry actions must be open the moment the menu
        opens, or the widget has buried the thing it exists to surface."""
        self.write_task("t-run", status="running")
        self.write_task("t-block", status="blocked")
        self.write_task("t-old", status="done", finished="2026-01-02T10:00:00")
        m = self.model()
        collapsed = {s["key"]: s["collapsed_by_default"] for s in m["sections"]}
        self.assertEqual(collapsed, {"running": False, "needs_you": False,
                                     "earlier": True})

    def test_empty_sections_are_dropped(self):
        self.write_task("t-run", status="running")
        self.assertEqual([s["key"] for s in self.model()["sections"]], ["running"])

    def section_ids(self, model, key):
        for s in model["sections"]:
            if s["key"] == key:
                return s["ids"]
        return []


# A real /status.json body, verbatim from the Pass's own fixture. Kept as raw
# bytes rather than rebuilt from the helpers above, so it keeps checking the
# widget against what the server actually sends: keys the contract lists but
# the payload omits (`title`, `started`, `elapsed_s`, `session_id`), a trailing
# slash on pass_url, UTC with six fractional digits, groups with zero counts,
# and a failed job sitting in the verify lane.
REAL_STATUS_SAMPLE = """
{"generated_at":"2026-09-04T15:39:33.984811+00:00","pass_url":"http://127.0.0.1:8811/","groups":[{"key":"gate","label":"Needs your go","count":1,"undone":1},{"key":"running","label":"Running","count":1,"undone":1},{"key":"verify","label":"Verify","count":2,"undone":2},{"key":"today","label":"Today","count":0,"undone":0},{"key":"next","label":"Next","count":0,"undone":0}],"counts":{"running":1,"verify":2,"gate":1,"blocked":0,"failed":1},"jobs":[{"item_id":"run1","state":"running","status":"running","session_id":"sess-abc","resume_url":"quicktask://resume/run1-7ab83a9b","report":null,"outputs":[]},{"item_id":"done1","state":"verify","status":"done","failed":false,"blocked":false,"resume_url":null,"report":"/job/done1/output/report.html","outputs":["report.html"]},{"item_id":"fail1","state":"verify","status":"failed","failed":true,"blocked":false,"resume_url":null,"report":null,"outputs":[]}],"needs_you":[{"item_id":"done1","state":"verify","reason":"verify"},{"item_id":"gate1","state":"gate","reason":"gate"},{"item_id":"fail1","state":"verify","reason":"failed"}]}
""".strip()


class TestRealStatusSample(PassCase):
    def setUp(self):
        super().setUp()
        self.base = self.serve(raw=REAL_STATUS_SAMPLE)
        self.m = self.pass_model(self.base)

    def test_the_real_payload_parses(self):
        self.assertEqual(self.m["source"], "pass")
        self.assertIsNone(self.m["pass_error"])
        self.assertEqual(self.m["count"], 4)

    def test_sections_and_needs_you_order(self):
        self.assertEqual([(s["key"], s["ids"]) for s in self.m["sections"]],
                         [("running", ["run1-7ab83a9b"]),
                          ("needs_you", ["done1", "gate1", "fail1"])])

    def test_the_resume_slug_is_the_row_id(self):
        r = self.by_id(self.m, "run1-7ab83a9b")
        self.assertEqual(r["item_id"], "run1")
        self.assertTrue(r["can_resume"])

    def test_report_url_survives_a_trailing_slash_on_pass_url(self):
        self.assertEqual(self.m["pass_url"], "http://127.0.0.1:8811/")
        self.assertEqual(self.by_id(self.m, "done1")["report_url"],
                         "http://127.0.0.1:8811/job/done1/output/report.html")

    def test_a_failed_job_in_the_verify_lane_still_takes_a_verdict(self):
        """The review page keys its actions off `state`, so state verify with
        reason failed reads "Failed" and still offers accept/redo/reject."""
        r = self.by_id(self.m, "fail1")
        self.assertEqual(r["state"], "verify")
        self.assertEqual(r["reason"], "failed")
        self.assertEqual(r["detail"], "Failed")
        self.assertEqual(r["status"], "failed")
        self.assertTrue(r["can_decide"])

    def test_a_gate_row_takes_no_verdict(self):
        r = self.by_id(self.m, "gate1")
        self.assertEqual(r["state"], "gate")
        self.assertEqual(r["detail"], "Needs go")
        self.assertFalse(r["can_decide"])
        self.assertFalse(r["can_resume"])

    def test_a_missing_title_falls_back_to_the_item_id(self):
        self.assertEqual(self.by_id(self.m, "done1")["title"], "done1")

    def test_generated_at_orders_a_row_without_dating_it(self):
        """Every job in the real payload omits `started`. generated_at stands
        in so the row sorts and counts as today, but it must not become the
        row's age: "Needs go - 2s" on an item held for a week would be a lie,
        and one that resets on every poll."""
        for row in self.m["records"]:
            self.assertIsNotNone(row["feed_stamp"], row["id"])
            self.assertTrue(row["feed_stamp"].startswith("2026-09-04T"), row["id"])
            # No timestamp of its own, so no age text and no stopwatch.
            self.assertIsNone(row["created"], row["id"])
            self.assertIsNone(row["started"], row["id"])
            self.assertIsNone(row["finished"], row["id"])
            self.assertIsNone(row["elapsed_s"], row["id"])

    def test_a_row_with_its_own_stamp_gets_no_feed_stamp(self):
        payload = json.loads(REAL_STATUS_SAMPLE)
        payload["jobs"][0]["started"] = "2026-09-04T15:00:00+00:00"
        base = self.serve(payload=payload)
        r = self.by_id(self.pass_model(base), "run1-7ab83a9b")
        self.assertIsNotNone(r["started"])
        self.assertIsNone(r["feed_stamp"])

    def test_zero_count_groups_are_carried_through(self):
        self.assertEqual([g["key"] for g in self.m["groups"]],
                         ["gate", "running", "verify", "today", "next"])
        self.assertEqual([g["count"] for g in self.m["groups"]],
                         [1, 1, 2, 0, 0])

    def test_utc_stamps_with_six_fractional_digits_parse(self):
        """`2026-09-04T15:39:33.984811+00:00`. An ISO-8601 parser accepting
        only three fractional digits would blank every timestamp."""
        payload = json.loads(REAL_STATUS_SAMPLE)
        payload["jobs"][0]["started"] = payload["generated_at"]
        payload["jobs"][0]["elapsed_s"] = 41
        base = self.serve(payload=payload)
        r = self.by_id(self.pass_model(base), "run1-7ab83a9b")
        self.assertIsNotNone(r["started"])
        self.assertTrue(r["started"].startswith("2026-09-04T"))
        self.assertEqual(r["elapsed_s"], 41)

    def test_a_v1_payload_offers_no_run_it_and_no_deep_link(self):
        """Everything v2 added is optional, and its absence has to read as
        "not available" rather than as a default that misfires."""
        self.assertIsNone(self.m["item_url_template"])
        self.assertFalse(self.m["truncated"])
        for row in self.m["records"]:
            self.assertFalse(row["can_run"], row["id"])
            self.assertEqual(row["denials"], 0, row["id"])
            self.assertIsNone(row["error"], row["id"])
            # No template, so the title still opens the Pass root.
            self.assertEqual(row["item_url"], self.m["pass_url"], row["id"])

    def test_a_finished_job_with_no_timestamps_lands_in_done_today(self):
        """A terminal job the Pass is reporting live, with nothing to date it
        by, belongs to today rather than behind the collapsed Earlier."""
        payload = json.loads(REAL_STATUS_SAMPLE)
        payload["needs_you"] = []
        payload["jobs"] = [j for j in payload["jobs"] if j["item_id"] == "done1"]
        # This one case has to move the sample's clock forward. The row it is
        # about carries no timestamp of its own, so `generated_at` is the only
        # thing placing it, and "today" is a claim about the day the payload was
        # generated -- which for a verbatim sample is the day it was captured.
        # Left as recorded it passed on 4 September 2026 and failed every day
        # after. Everything else about the sample stays byte-for-byte.
        payload["generated_at"] = _iso(datetime.now())
        base = self.serve(payload=payload)
        m = self.pass_model(base)
        self.assertEqual([s["key"] for s in m["sections"]], ["done_today"])


# A real /status.json v2 body, verbatim in the shape hub/serve.py's
# _status_payload() builds: every key it sends, in its order, including the ones
# v2 added -- item_url_template, counts.done_today/total_jobs/truncated, and
# per-job finished/error/denials/can_run, plus the affordances needs_you now
# carries on its own (resume_url, report, session_id, started, can_run).
#
# done1's `finished` is deliberately *not* started + elapsed_s (15:20 + 480s
# would be 15:28, and it says 15:31), so a test can tell a parsed finish time
# apart from the reconstructed one v1 had to use.
REAL_STATUS_V2_SAMPLE = """
{"generated_at":"2026-09-04T15:39:33.984811+00:00","pass_url":"http://127.0.0.1:8811/","item_url_template":"http://127.0.0.1:8811/?item={item_id}","groups":[{"key":"gate","label":"Needs your go","count":1,"undone":1},{"key":"running","label":"Running","count":1,"undone":1},{"key":"verify","label":"Verify","count":2,"undone":2},{"key":"today","label":"Today","count":0,"undone":0}],"counts":{"running":1,"verify":2,"gate":1,"blocked":0,"failed":1,"total_jobs":3,"truncated":false,"done_today":2},"jobs":[{"item_id":"run1","title":"Running one","state":"running","status":"running","started":"2026-09-04T15:38:00+00:00","elapsed_s":93,"failed":false,"blocked":false,"session_id":"sess-abc","resume_url":"quicktask://resume/run1-20260904-153800-7ab83a","report":null,"outputs":[],"finished":null,"error":null,"denials":0,"can_run":false},{"item_id":"done1","title":"Done one","state":"verify","status":"done","started":"2026-09-04T15:20:00+00:00","elapsed_s":480,"failed":false,"blocked":false,"session_id":"","resume_url":null,"report":"/job/done1/output/report.html","outputs":["RESULT.md","report.html"],"finished":"2026-09-04T15:31:00+00:00","error":null,"denials":0,"can_run":false},{"item_id":"fail1","title":"Failed one","state":"verify","status":"failed","started":"2026-09-04T14:00:00+00:00","elapsed_s":61,"failed":true,"blocked":false,"session_id":"","resume_url":null,"report":null,"outputs":[],"finished":"2026-09-04T14:01:01+00:00","error":"boom: something failed","denials":2,"can_run":false}],"needs_you":[{"item_id":"done1","title":"Done one","state":"verify","reason":"verify","resume_url":null,"report":"/job/done1/output/report.html","session_id":"","started":"2026-09-04T15:20:00+00:00","can_run":false},{"item_id":"gate1","title":"Gate one","state":"gate","reason":"gate","resume_url":null,"report":null,"session_id":"","started":"2026-08-27","can_run":true},{"item_id":"fail1","title":"Failed one","state":"verify","reason":"failed","resume_url":null,"report":null,"session_id":"","started":"2026-09-04T14:00:00+00:00","can_run":false}]}
""".strip()


class TestStatusV2Sample(PassCase):
    """The v2 payload, parsed field by field. No section or day assertions --
    the sample's timestamps are fixed, so those live in TestDoneTodayByFinished
    where they are generated relative to now."""

    def setUp(self):
        super().setUp()
        self.base = self.serve(raw=REAL_STATUS_V2_SAMPLE)
        self.m = self.pass_model(self.base)

    def test_the_v2_payload_parses(self):
        self.assertEqual(self.m["source"], "pass")
        self.assertIsNone(self.m["pass_error"])
        self.assertEqual(self.m["count"], 4, self.ids(self.m))

    def test_titles_come_from_the_payload_now(self):
        """v2 always sends a title, on both lists. The id fallback stays for an
        empty one, but it should no longer be what rows are named."""
        titles = {r["item_id"]: r["title"] for r in self.m["records"]}
        self.assertEqual(titles["done1"], "Done one")
        self.assertEqual(titles["gate1"], "Gate one")
        self.assertEqual(titles["fail1"], "Failed one")
        self.assertEqual(titles["run1"], "Running one")

    def test_an_empty_title_still_falls_back_to_the_id(self):
        payload = json.loads(REAL_STATUS_V2_SAMPLE)
        payload["needs_you"][1]["title"] = ""
        base = self.serve(payload=payload)
        self.assertEqual(self.by_id(self.pass_model(base), "gate1")["title"], "gate1")

    def test_finished_is_read_rather_than_reconstructed(self):
        """15:20 + 480s would be 15:28. The payload says 15:31, and that is the
        number Done today has to be decided by."""
        r = self.by_id(self.m, "done1")
        self.assertTrue(r["finished"].startswith("2026-09-04T15:31"), r["finished"])

    def test_a_running_job_has_no_finish_time(self):
        # Identity is still the resume slug, not the item id.
        self.assertIsNone(self.by_id(self.m, "run1-20260904-153800-7ab83a")["finished"])

    def test_error_and_denial_count_come_through(self):
        """Both feed the row's tooltip, and both are the reason you would want
        this row rather than its neighbour."""
        r = self.by_id(self.m, "fail1")
        self.assertEqual(r["error"], "boom: something failed")
        self.assertEqual(r["denials"], 2, "v2 sends a count, not the array")
        self.assertEqual(r["outputs"], 0)
        self.assertEqual(self.by_id(self.m, "done1")["outputs"], 2)

    def test_a_v1_denials_array_still_counts(self):
        base = self.serve(payload=status_fixture(
            jobs=[job("j-old", denials=[{"tool_name": "Bash"}, {"tool_name": "Write"}])]))
        self.assertEqual(self.by_id(self.pass_model(base), "j-old")["denials"], 2)

    def test_can_run_is_the_pass_s_own_verdict(self):
        """The rule needs the item's prompt and its lane, so it is decided
        server-side and the widget just reports it."""
        by_item = {r["item_id"]: r for r in self.m["records"]}
        self.assertTrue(by_item["gate1"]["can_run"], "a gate item with a prompt is fireable")
        self.assertFalse(by_item["run1"]["can_run"], "already running")
        self.assertFalse(by_item["done1"]["can_run"], "awaiting a verdict")
        self.assertFalse(by_item["fail1"]["can_run"], "awaiting a verdict")

    def test_a_gate_row_now_arrives_with_its_own_timestamp(self):
        """v2's needs_you carries `started`, which for a gate item is the item's
        own ledger date. So the row finally has a real age instead of borrowing
        generated_at for ordering."""
        r = self.by_id(self.m, "gate1")
        self.assertIsNotNone(r["started"])
        self.assertTrue(r["started"].startswith("2026-08-27"), r["started"])
        self.assertIsNone(r["feed_stamp"], "it has a stamp of its own now")

    def test_counts_and_truncated_come_through(self):
        self.assertEqual(self.m["counts"], {
            "running": 1, "verify": 2, "gate": 1, "blocked": 0, "failed": 1,
            "total_jobs": 3, "done_today": 2,
        })
        self.assertFalse(self.m["truncated"])
        self.assertNotIn("truncated", self.m["counts"],
                         "truncated is a flag, not a tally; it must not read as 1")

    def test_truncated_is_carried_as_a_flag(self):
        payload = json.loads(REAL_STATUS_V2_SAMPLE)
        payload["counts"]["truncated"] = True
        payload["counts"]["total_jobs"] = 412
        base = self.serve(payload=payload)
        m = self.pass_model(base)
        self.assertTrue(m["truncated"])
        self.assertEqual(m["counts"]["total_jobs"], 412)

    def test_needs_you_affordances_no_longer_need_the_job(self):
        """v2 made needs_you self-sufficient, which matters exactly when the
        job has been capped out of jobs[]: the row still resumes and still has
        its report."""
        base = self.serve(payload=status_fixture(
            jobs=[],
            needs=[need("ld188", "verify", state="verify",
                        resume_url="quicktask://resume/ld188-20260904-101500-a1b2c3",
                        report="/job/ld188/output/report.html",
                        session_id="sess-ld188",
                        started=_iso(datetime.now() - timedelta(minutes=20)),
                        can_run=False)]))
        r = self.by_id(self.pass_model(base), "ld188-20260904-101500-a1b2c3")
        self.assertEqual(r["item_id"], "ld188")
        self.assertTrue(r["can_resume"])
        self.assertEqual(r["session_id"], "sess-ld188")
        self.assertEqual(r["report"], "/job/ld188/output/report.html")
        self.assertEqual(r["report_url"], base + "/job/ld188/output/report.html")
        self.assertIsNotNone(r["started"])
        self.assertTrue(r["can_decide"])

    def test_the_needs_you_entry_wins_over_the_job(self):
        """Both sides send most fields now. The row's own view of itself is the
        one taken, so a stale jobs[] entry cannot rename or re-lane it."""
        base = self.serve(payload=status_fixture(
            jobs=[job("x", title="stale title", state="today", session_id="stale-sess")],
            needs=[need("x", "verify", title="fresh title", state="verify",
                        session_id="fresh-sess")]))
        r = self.by_id(self.pass_model(base), "x")
        self.assertEqual(r["title"], "fresh title")
        self.assertEqual(r["state"], "verify")
        self.assertEqual(r["session_id"], "fresh-sess")

    def test_an_explicit_null_does_not_hide_the_job_s_value(self):
        """A JSON null is present but says nothing, so it has to read as absent.
        Otherwise a needs_you entry sending `"resume_url": null` would hide a
        real session sitting on the job side."""
        base = self.serve(payload=status_fixture(
            jobs=[job("ld188", status="done", state="verify",
                      report="/job/ld188/output/report.html",
                      session_id="sess-ld188",
                      resume_url="quicktask://resume/ld188-20260904-101500-a1b2c3")],
            needs=[need("ld188", "verify", state="verify", resume_url=None,
                        report=None, session_id=None, started=None)]))
        r = self.by_id(self.pass_model(base), "ld188-20260904-101500-a1b2c3")
        self.assertEqual(r["resume_url"],
                         "quicktask://resume/ld188-20260904-101500-a1b2c3")
        self.assertEqual(r["report"], "/job/ld188/output/report.html")
        self.assertEqual(r["session_id"], "sess-ld188")
        self.assertTrue(r["can_resume"])

    def test_elapsed_and_outputs_still_come_from_the_job(self):
        """The two fields only the job side has, so the join still earns its
        keep even with needs_you self-sufficient."""
        base = self.serve(payload=status_fixture(
            jobs=[job("y", status="running", elapsed_s=252, outputs=["a.md", "b.md"])],
            needs=[need("y", "blocked")]))
        r = self.by_id(self.pass_model(base), "y")
        self.assertEqual(r["elapsed_s"], 252)
        self.assertEqual(r["outputs"], 2)


class TestDoneTodayByFinished(PassCase):
    """Which day a finished row belongs to is decided by `finished`, and only
    falls back to the old started + elapsed_s reconstruction when the payload
    carries none."""

    def section_of(self, base, item_id):
        return self.by_id(self.pass_model(base), item_id)["section"]

    def test_a_job_that_finished_today_is_done_today(self):
        base = self.serve(payload=status_fixture(
            jobs=[job("j", status="done", state="today",
                      started=_iso(datetime.now() - timedelta(days=4)),
                      elapsed_s=30,
                      finished=_iso(datetime.now() - timedelta(minutes=10)))]))
        self.assertEqual(self.section_of(base, "j"), "done_today",
                         "started four days ago, finished ten minutes ago")

    def test_a_job_that_finished_yesterday_is_earlier(self):
        """And started + elapsed_s must not drag it into today: this one
        started an hour ago by that arithmetic, and still finished yesterday."""
        base = self.serve(payload=status_fixture(
            jobs=[job("j", status="done", state="today",
                      started=_iso(datetime.now() - timedelta(hours=1)),
                      elapsed_s=60,
                      finished=_iso(datetime.now() - timedelta(days=1)))]))
        self.assertEqual(self.section_of(base, "j"), "earlier")

    def test_a_v1_payload_still_reconstructs_the_finish(self):
        base = self.serve(payload=status_fixture(
            jobs=[job("j", status="done", state="today", elapsed_s=480,
                      started=_iso(datetime.now() - timedelta(hours=2)))]))
        r = self.by_id(self.pass_model(base), "j")
        self.assertIsNotNone(r["finished"])
        self.assertEqual(r["section"], "done_today")

    def test_a_null_finish_on_a_running_job_stays_running(self):
        base = self.serve(payload=status_fixture(
            jobs=[job("j", status="running", finished=None)]))
        r = self.by_id(self.pass_model(base), "j")
        self.assertIsNone(r["finished"])
        self.assertEqual(r["section"], "running")

    def test_finished_beats_the_feed_stamp_for_an_old_job(self):
        """A row with no `started` used to fall back to generated_at and land
        in today. With a real finish time it goes where it belongs."""
        base = self.serve(payload=status_fixture(
            jobs=[job("j", status="done", state="today", started=None, elapsed_s=None,
                      finished=_iso(datetime.now() - timedelta(days=3)))]))
        self.assertEqual(self.section_of(base, "j"), "earlier")


class TestRunIt(PassCase):
    """POST /run: the body, the round trip, and the 409 that is an answer
    rather than a fault."""

    def test_the_run_body_is_just_the_item_id(self):
        body = json.loads(self.run_binary("--dump-run", "ld188").stdout)
        self.assertEqual(body, {"id": "ld188"})

    def test_the_run_body_trims_and_refuses_empty(self):
        body = json.loads(self.run_binary("--dump-run", "  ld188  ").stdout)
        self.assertEqual(body, {"id": "ld188"})
        self.run_binary("--dump-run", "   ", expect=1)

    def test_running_an_item_posts_the_id_to_run(self):
        base = self.serve(payload=status_fixture(
            needs=[need("gate1", "gate", can_run=True)]),
            post_body={"ok": True, "job": "gate1-20260904-120000-abc123"})
        proc = self.run_binary("--post-run", "gate1", extra_env={"QT_PASS_URL": base})
        self.assertEqual(json.loads(proc.stdout),
                         {"ok": True, "job": "gate1-20260904-120000-abc123"})
        posts = [p for p in self.server.posts if p["path"] == "/run"]
        self.assertEqual(len(posts), 1, self.server.posts)
        self.assertEqual(posts[0]["body"], {"id": "gate1"})
        # Same hole the other posts come in by: serve.py lets a request with no
        # Origin through, and a native app is what that is for.
        self.assertNotIn("Origin", posts[0]["headers"])
        self.assertEqual(posts[0]["headers"].get("Content-Type"), "application/json")

    def test_a_409_reads_as_already_running(self):
        base = self.serve(payload=status_fixture(), post_code=409,
                          post_text="already running")
        proc = self.run_binary("--post-run", "gate1", extra_env={"QT_PASS_URL": base},
                               expect=1)
        self.assertEqual(json.loads(proc.stdout),
                         {"ok": False, "error": "Already running"})

    def test_a_409_for_a_full_queue_says_so(self):
        """serve.py sends "max concurrent jobs running" when all three slots
        are busy. Not an HTTP status in the header, and not a stack of words
        either -- it has to fit next to the dot."""
        base = self.serve(payload=status_fixture(), post_code=409,
                          post_text="max concurrent jobs running")
        proc = self.run_binary("--post-run", "gate1", extra_env={"QT_PASS_URL": base},
                               expect=1)
        self.assertEqual(json.loads(proc.stdout)["error"], "Job slots full, not fired")

    def test_an_unexpected_409_body_is_still_reported(self):
        base = self.serve(payload=status_fixture(), post_code=409,
                          post_text="something new upstream")
        proc = self.run_binary("--post-run", "gate1", extra_env={"QT_PASS_URL": base},
                               expect=1)
        self.assertEqual(json.loads(proc.stdout)["error"],
                         "Not fired: something new upstream")

    def test_a_400_is_not_dressed_up_as_a_refusal(self):
        """An unknown id or a promptless item is a 400, which is a fault on the
        widget's side and should read like one."""
        base = self.serve(payload=status_fixture(), post_code=400,
                          post_text="unknown id")
        proc = self.run_binary("--post-run", "nope", extra_env={"QT_PASS_URL": base},
                               expect=1)
        self.assertIn("400", json.loads(proc.stdout)["error"])

    def test_an_unreachable_pass_is_not_a_silent_no_op(self):
        proc = self.run_binary("--post-run", "gate1",
                               extra_env={"QT_PASS_URL": "http://127.0.0.1:1"}, expect=1)
        self.assertFalse(json.loads(proc.stdout)["ok"])

    def test_running_needs_a_pass(self):
        """QT_PASS_URL="" means the file ledgers only, and the file feed has no
        route to fire anything."""
        self.run_binary("--post-run", "gate1", extra_env={"QT_PASS_URL": ""}, expect=1)

    def test_a_file_feed_row_never_offers_run_it(self):
        """can_run needs the item's prompt and lane, and neither ledger has
        them, so the button has to stay off in file mode."""
        self.write_task("t-local", status="done")
        m = self.model()
        self.assertEqual(m["source"], "files")
        self.assertFalse(any(r["can_run"] for r in m["records"]))


class TestItemDeepLink(PassCase):
    """Clicking a title opens the item, not the top of the page."""

    def test_the_template_is_filled_with_the_item_id(self):
        base = self.serve(payload=status_fixture(
            jobs=[job("ld188", status="running")],
            pass_url="http://127.0.0.1:8899/",
            item_url_template="http://127.0.0.1:8899/?item={item_id}"))
        m = self.pass_model(base)
        self.assertEqual(m["item_url_template"], "http://127.0.0.1:8899/?item={item_id}")
        self.assertEqual(self.by_id(m, "ld188")["item_url"],
                         "http://127.0.0.1:8899/?item=ld188")

    def test_the_link_uses_the_item_id_not_the_row_id(self):
        """The row's identity is the resume slug; every Pass route is keyed by
        the item id, and so is this."""
        base = self.serve(payload=status_fixture(
            jobs=[job("ld188", status="done", state="verify",
                      resume_url="quicktask://resume/ld188-20260904-101500-a1b2c3")],
            item_url_template="http://127.0.0.1:8811/?item={item_id}"))
        r = self.by_id(self.pass_model(base), "ld188-20260904-101500-a1b2c3")
        self.assertEqual(r["item_url"], "http://127.0.0.1:8811/?item=ld188")

    def test_an_id_needing_encoding_is_encoded(self):
        base = self.serve(payload=status_fixture(
            needs=[need("cap 2026&09", "gate")],
            item_url_template="http://127.0.0.1:8811/?item={item_id}"))
        r = self.by_id(self.pass_model(base), "cap 2026&09")
        self.assertEqual(r["item_url"], "http://127.0.0.1:8811/?item=cap%202026%2609",
                         "the id is a query value, so an & in it has to be escaped")

    def test_no_template_falls_back_to_the_pass_root(self):
        """A v1 payload has no template, and an dead click would be worse than
        landing on the page."""
        base = self.serve(payload=status_fixture(jobs=[job("ld188")]))
        m = self.pass_model(base)
        self.assertIsNone(m["item_url_template"])
        self.assertEqual(self.by_id(m, "ld188")["item_url"], base)

    def test_a_template_without_the_placeholder_falls_back(self):
        base = self.serve(payload=status_fixture(
            jobs=[job("ld188")], pass_url="http://127.0.0.1:8899/",
            item_url_template="http://127.0.0.1:8899/"))
        self.assertEqual(self.by_id(self.pass_model(base), "ld188")["item_url"],
                         "http://127.0.0.1:8899/")

    def test_a_file_row_falls_back_to_the_pass_root(self):
        self.write_task("t-local", status="done")
        m = self.model()
        self.assertIsNone(m["item_url_template"])
        self.assertEqual(self.by_id(m, "t-local")["item_url"], m["pass_url"])


class TestPassDiscovery(ModelCase):
    """Where the widget looks for The Pass: QT_PASS_URL, then the hub
    checkout's .pass-url, then port 8811. Driven through --dump-endpoint, which
    makes no request -- so these cases never touch a live Pass."""

    def test_the_env_override_wins(self):
        self.write_pass_url("http://127.0.0.1:8877/\n")
        e = self.endpoint(extra_env={"QT_PASS_URL": "http://127.0.0.1:9999"})
        self.assertEqual(e["pass_url"], "http://127.0.0.1:9999")
        self.assertEqual(e["source"], "env")

    def test_the_file_wins_over_the_default(self):
        """serve.py walks 8811..8820 for a free port and writes where it landed,
        which is the whole reason this file exists."""
        self.write_pass_url("http://127.0.0.1:8813/\n")
        e = self.endpoint()
        self.assertEqual(e["pass_url"], "http://127.0.0.1:8813/")
        self.assertEqual(e["source"], "file")
        self.assertEqual(e["file"], str(self.hub / ".pass-url"))
        self.assertIsNone(e["file_problem"])

    def test_surrounding_whitespace_is_trimmed(self):
        self.write_pass_url("  http://localhost:8815/  \n\n")
        e = self.endpoint()
        self.assertEqual(e["pass_url"], "http://localhost:8815/")
        self.assertEqual(e["source"], "file")

    def test_no_file_means_the_default_port(self):
        """The normal state when The Pass is down: it removes the file on a
        graceful shutdown, and that is not an error."""
        e = self.endpoint()
        self.assertEqual(e["pass_url"], "http://127.0.0.1:8811")
        self.assertEqual(e["source"], "default")
        self.assertIsNone(e["file_problem"])

    def test_a_malformed_file_is_ignored_and_reported(self):
        self.write_pass_url("not a url at all\n")
        e = self.endpoint()
        self.assertEqual(e["pass_url"], "http://127.0.0.1:8811")
        self.assertEqual(e["source"], "default")
        self.assertIn("not a URL", e["file_problem"])

    def test_an_empty_file_is_ignored(self):
        """A file caught mid-write must not take the feed down with it."""
        self.write_pass_url("\n")
        e = self.endpoint()
        self.assertEqual(e["source"], "default")
        self.assertIn("empty", e["file_problem"])

    def test_a_non_loopback_file_is_refused(self):
        """This is a file the widget reads without being told to, so it does
        not get to choose the host."""
        self.write_pass_url("http://evil.example.com:8811/\n")
        e = self.endpoint()
        self.assertEqual(e["pass_url"], "http://127.0.0.1:8811")
        self.assertIn("loopback", e["file_problem"])

    def test_a_non_http_file_is_refused(self):
        self.write_pass_url("file:///Users/someone/code/hub\n")
        e = self.endpoint()
        self.assertEqual(e["source"], "default")
        self.assertIn("not http", e["file_problem"])

    def test_an_empty_env_override_switches_the_feed_off(self):
        self.write_pass_url("http://127.0.0.1:8813/\n")
        e = self.endpoint(extra_env={"QT_PASS_URL": ""})
        self.assertIsNone(e["pass_url"])
        self.assertEqual(e["source"], "off")

    def test_the_file_is_read_from_the_configured_hub(self):
        """Only the hub the widget is pointed at, so it never discovers a Pass
        belonging to a checkout it was not asked about."""
        other = self.tmp / "other-hub"
        other.mkdir()
        (other / ".pass-url").write_text("http://127.0.0.1:8888/\n")
        e = self.endpoint(extra_env={"QT_HUB": str(other)})
        self.assertEqual(e["pass_url"], "http://127.0.0.1:8888/")
        self.assertEqual(e["file"], str(other / ".pass-url"))

    def test_the_discovered_url_is_actually_used(self):
        """End to end: a .pass-url pointing at a live fixture server has to be
        the thing the model comes from, with no QT_PASS_URL in sight."""
        server = FixturePass(payload=status_fixture(jobs=[job("alpha", status="running")]))
        base = server.start()
        self.addCleanup(server.stop)
        self.write_pass_url(base + "\n")
        env = dict(os.environ)
        env.pop("QT_PASS_URL", None)
        env["QT_DATA"] = str(self.qt_data)
        env["QT_HUB"] = str(self.hub)
        env["QT_MENUBAR_AGENT_PLIST"] = str(self.tmp / "agents" / "never-written.plist")
        proc = subprocess.run([str(BINARY), "--dump-model", "--limit", "50"],
                              capture_output=True, text=True, timeout=60, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        m = json.loads(proc.stdout)
        self.assertEqual(m["source"], "pass")
        self.assertEqual(m["pass_url_source"], "file")
        self.assertEqual(self.ids(m), ["alpha"])


class TestKeyboardHighlight(PassCase):
    """up/down walk the visible rows, return takes the row's primary action,
    escape clears. Driven through --dump-keys, which runs the same pure
    KeyboardNav the view uses."""

    def keys(self, base, sequence):
        proc = self.run_binary("--dump-keys", sequence,
                               extra_env={"QT_PASS_URL": base})
        return json.loads(proc.stdout)

    def three_rows(self):
        return self.serve(payload=status_fixture(
            jobs=[job("j-live", status="running",
                      resume_url="quicktask://resume/j-live-20260904-120000-aaaaaa")],
            needs=[need("g-gate", "gate", can_run=True),
                   need("j-block", "blocked")],
            item_url_template="http://127.0.0.1:8811/?item={item_id}"))

    def test_visible_rows_are_the_rows_in_reading_order(self):
        base = self.three_rows()
        m = self.pass_model(base)
        self.assertEqual(m["visible_ids"],
                         ["j-live-20260904-120000-aaaaaa", "g-gate", "j-block"])

    def test_a_collapsed_section_is_not_walked(self):
        """Earlier starts collapsed, so its rows are not in the highlight's
        path -- the highlight has to walk the list the eye is walking."""
        base = self.serve(payload=status_fixture(
            jobs=[job("j-old", status="done", state="today",
                      finished=_iso(datetime.now() - timedelta(days=3)),
                      started=_iso(datetime.now() - timedelta(days=3)))],
            needs=[need("g-gate", "gate")]))
        m = self.pass_model(base)
        self.assertEqual(self.by_id(m, "j-old")["section"], "earlier")
        self.assertEqual(m["visible_ids"], ["g-gate"])

    def test_down_from_nothing_highlights_the_first_row(self):
        self.assertEqual(self.keys(self.three_rows(), "down")["highlight"],
                         "j-live-20260904-120000-aaaaaa")

    def test_up_from_nothing_highlights_the_last_row(self):
        self.assertEqual(self.keys(self.three_rows(), "up")["highlight"], "j-block")

    def test_the_highlight_walks_down_and_back_up(self):
        base = self.three_rows()
        self.assertEqual(self.keys(base, "down,down")["highlight"], "g-gate")
        self.assertEqual(self.keys(base, "down,down,down")["highlight"], "j-block")
        self.assertEqual(self.keys(base, "down,down,up")["highlight"],
                         "j-live-20260904-120000-aaaaaa")

    def test_the_ends_do_not_wrap(self):
        """A held arrow stopping at the end of the list is easier to follow
        than one that teleports to the other end."""
        base = self.three_rows()
        self.assertEqual(self.keys(base, "down,down,down,down,down")["highlight"],
                         "j-block")
        self.assertEqual(self.keys(base, "down,up,up,up")["highlight"],
                         "j-live-20260904-120000-aaaaaa")

    def test_escape_clears_the_highlight(self):
        self.assertIsNone(self.keys(self.three_rows(), "down,down,escape")["highlight"])

    def test_return_resumes_when_there_is_a_session(self):
        k = self.keys(self.three_rows(), "down")
        self.assertEqual(k["primary_action"], "resume")
        self.assertEqual(k["primary_url"],
                         "quicktask://resume/j-live-20260904-120000-aaaaaa")

    def test_return_opens_the_item_when_there_is_no_session(self):
        """Never a verdict and never a fire: both of those ask first, and a
        keystroke that spends a job slot is not one to discover by accident."""
        k = self.keys(self.three_rows(), "down,down")
        self.assertEqual(k["highlight"], "g-gate")
        self.assertEqual(k["primary_action"], "item")
        self.assertEqual(k["primary_url"], "http://127.0.0.1:8811/?item=g-gate")

    def test_nothing_to_walk_is_not_an_error(self):
        base = self.serve(payload=status_fixture(jobs=[], needs=[]))
        k = self.keys(base, "down,down,up")
        self.assertEqual(k["visible_ids"], [])
        self.assertIsNone(k["highlight"])

    def test_an_unknown_key_is_refused_rather_than_ignored(self):
        base = self.serve(payload=status_fixture(needs=[need("g", "gate")]))
        proc = self.run_binary("--dump-keys", "down,left",
                               extra_env={"QT_PASS_URL": base}, expect=1)
        self.assertIn("left", proc.stderr)


class TestCaptureLimits(ModelCase):
    def test_capture_takes_text_up_to_the_limit(self):
        proc = self.run_binary("--dump-capture", "x" * 4000)
        self.assertEqual(len(json.loads(proc.stdout)["text"]), 4000)

    def test_capture_refuses_text_over_the_limit(self):
        """POST /capture answers 400 over 4000 characters, so the widget says
        so in its own words rather than surfacing an HTTP status."""
        proc = self.run_binary("--dump-capture", "x" * 4001, expect=1)
        self.assertIn("4001", proc.stderr)
        self.assertIn("4000", proc.stderr)


if __name__ == "__main__":
    unittest.main()

# --- fixtures for the suggestions contract -----------------------------
#
# status_fixture() predates `suggestions`, and has no keyword for it, so this
# wraps it rather than editing the shared helper (per the brief: define a
# local helper when the shared one is missing a keyword). suggestions=None
# omits the key entirely, which is the only way to pin suggestions_available
# False; passing [] pins it True with nothing to show -- that distinction is
# the whole point of two of the tests below.

def suggestion_fixture(item_id, **fields):
    """One suggestions[] entry, with the contract's full key set."""
    rec = {
        "item_id": item_id,
        "title": fields.pop("title", f"title for {item_id}"),
        "rationale": fields.pop("rationale", f"rationale for {item_id}"),
        "confidence": fields.pop("confidence", 0.5),
        "proposed": fields.pop("proposed", "track"),
        "source": fields.pop("source", "slack"),
        "source_url": fields.pop("source_url", f"https://example.com/{item_id}"),
        "date": fields.pop("date", _iso(datetime.now())),
    }
    rec.update(fields)
    return rec


def status_fixture_with_suggestions(suggestions=None, **kwargs):
    payload = status_fixture(**kwargs)
    if suggestions is not None:
        payload["suggestions"] = list(suggestions)
    return payload


# A private defaults suite for every model()/run_binary() call below, so a
# real com.quicktasks.menubar preference on this machine can never steer a
# suggestions test, and nothing here reads or writes that real domain.
_SUGGEST_DEFAULTS_ENV = {"QT_MENUBAR_DEFAULTS_SUITE": "com.quicktasks.menubar.testsuggest"}

# Pinned from Suggestion.confidenceStep in Model.swift (>= high is step 3,
# >= medium is step 2, else step 1), so the pip-threshold test below derives
# its expected steps from these two constants rather than restating them.
_SUGGEST_CONFIDENCE_HIGH = 0.75
_SUGGEST_CONFIDENCE_MEDIUM = 0.45


class TestSuggestionsParsing(PassCase):
    """The `suggestions` array and `counts.suggest`, via `--dump-model`."""

    def dump_model(self, base, *extra_args, expect=0):
        proc = self.run_binary("--dump-model", "--limit", "50", *extra_args,
                               extra_env={"QT_PASS_URL": base, **_SUGGEST_DEFAULTS_ENV},
                               expect=expect)
        return json.loads(proc.stdout)

    def test_three_suggestions_parse_in_payload_order_with_fields_carried_through(self):
        s1 = suggestion_fixture("sugg-1", title="Reply to Dan",
                                rationale="Dan asked twice in #eng",
                                proposed="fire", source="slack",
                                source_url="https://example.com/1")
        s2 = suggestion_fixture("sugg-2", title="Review PR 42",
                                rationale="you are the last reviewer",
                                proposed="track", source="github",
                                source_url="https://example.com/2")
        s3 = suggestion_fixture("sugg-3", title="Draft the LD-201 update",
                                rationale="due Friday",
                                proposed="today", source="linear",
                                source_url="https://example.com/3")
        base = self.serve(payload=status_fixture_with_suggestions(
            suggestions=[s1, s2, s3]))
        m = self.dump_model(base)
        self.assertEqual([s["item_id"] for s in m["suggestions"]],
                         ["sugg-1", "sugg-2", "sugg-3"])
        for got, want in zip(m["suggestions"], (s1, s2, s3)):
            self.assertEqual(got["title"], want["title"])
            self.assertEqual(got["rationale"], want["rationale"])
            self.assertEqual(got["proposed"], want["proposed"])
            self.assertEqual(got["source"], want["source"])
            self.assertEqual(got["source_url"], want["source_url"])
        self.assertEqual(m["suggestions_headline"], "3 things we think you need to do")

    def test_one_suggestion_headline_is_singular(self):
        base = self.serve(payload=status_fixture_with_suggestions(
            suggestions=[suggestion_fixture("sugg-1")]))
        m = self.dump_model(base)
        self.assertEqual(m["suggestions_headline"], "1 thing we think you need to do")

    def test_suggestions_key_absent_from_the_payload_hides_the_section(self):
        """No `suggestions` key at all is the shape every Pass sends today,
        since the suggestion engine has not shipped. The section has to look
        absent, not broken."""
        base = self.serve(payload=status_fixture())
        m = self.dump_model(base)
        self.assertFalse(m["suggestions_available"])
        self.assertFalse(m["shows_suggestions"])
        self.assertEqual(m["suggestions"], [])

    def test_suggestions_key_present_but_empty_is_available_with_nothing_to_show(self):
        """The distinction is the point: this Pass has the engine and simply
        has nothing to suggest right now."""
        base = self.serve(payload=status_fixture_with_suggestions(suggestions=[]))
        m = self.dump_model(base)
        self.assertTrue(m["suggestions_available"])
        self.assertFalse(m["shows_suggestions"])

    def test_counts_suggest_tally_is_carried_through_like_every_other_count(self):
        base = self.serve(payload=status_fixture_with_suggestions(
            suggestions=[suggestion_fixture("sugg-1")],
            counts={"running": 0, "verify": 0, "gate": 0, "blocked": 0,
                   "failed": 0, "suggest": 4}))
        m = self.dump_model(base)
        self.assertEqual(m["counts"]["suggest"], 4)

    def test_confidence_maps_to_a_three_step_pip_at_the_documented_thresholds(self):
        values = {
            "below-medium": (_SUGGEST_CONFIDENCE_MEDIUM - 0.01, 1),
            "at-medium": (_SUGGEST_CONFIDENCE_MEDIUM, 2),
            "below-high": (_SUGGEST_CONFIDENCE_HIGH - 0.01, 2),
            "at-high": (_SUGGEST_CONFIDENCE_HIGH, 3),
        }
        suggestions = [suggestion_fixture(item_id, confidence=conf)
                       for item_id, (conf, _step) in values.items()]
        base = self.serve(payload=status_fixture_with_suggestions(suggestions=suggestions))
        m = self.dump_model(base)
        got_steps = {s["item_id"]: s["confidence_step"] for s in m["suggestions"]}
        want_steps = {item_id: step for item_id, (_conf, step) in values.items()}
        self.assertEqual(got_steps, want_steps)

    def test_confidence_outside_zero_one_is_clamped_not_dropped(self):
        """A bad number upstream must not lose the row."""
        base = self.serve(payload=status_fixture_with_suggestions(suggestions=[
            suggestion_fixture("sugg-hi", confidence=1.7),
            suggestion_fixture("sugg-lo", confidence=-0.3),
        ]))
        m = self.dump_model(base)
        hi = next(s for s in m["suggestions"] if s["item_id"] == "sugg-hi")
        lo = next(s for s in m["suggestions"] if s["item_id"] == "sugg-lo")
        self.assertEqual(hi["confidence"], 1.0)
        self.assertEqual(hi["confidence_step"], 3)
        self.assertEqual(lo["confidence"], 0.0)
        self.assertEqual(lo["confidence_step"], 1)

    def test_a_suggestion_with_no_item_id_is_dropped(self):
        """Every one of the four decide buttons posts this id, so a row
        without one has four buttons that would all fail."""
        base = self.serve(payload=status_fixture_with_suggestions(suggestions=[
            {"title": "no id at all"},
            {"item_id": "", "title": "empty id"},
            suggestion_fixture("sugg-keep"),
        ]))
        m = self.dump_model(base)
        self.assertEqual([s["item_id"] for s in m["suggestions"]], ["sugg-keep"])

    def test_a_suggestion_with_no_title_falls_back_to_its_item_id(self):
        base = self.serve(payload=status_fixture_with_suggestions(
            suggestions=[{"item_id": "bare-item"}]))
        m = self.dump_model(base)
        self.assertEqual(m["suggestions"][0]["title"], "bare-item")

    def test_missing_optional_fields_are_all_tolerated(self):
        base = self.serve(payload=status_fixture_with_suggestions(
            suggestions=[{"item_id": "sparse-1", "title": "Sparse"}]))
        m = self.dump_model(base)
        row = m["suggestions"][0]
        self.assertEqual(row["rationale"], "")
        self.assertEqual(row["proposed"], "")
        self.assertEqual(row["source"], "other")
        self.assertIsNone(row["source_raw"])
        self.assertIsNone(row["source_url"])
        self.assertIsNone(row["date"])

    def test_an_unknown_source_keeps_its_raw_text_while_source_reads_other(self):
        base = self.serve(payload=status_fixture_with_suggestions(
            suggestions=[suggestion_fixture("sugg-1", source="asana")]))
        m = self.dump_model(base)
        row = m["suggestions"][0]
        self.assertEqual(row["source"], "other")
        self.assertEqual(row["source_raw"], "asana")

    def test_suggestions_do_not_leak_into_task_records_or_sections(self):
        base = self.serve(payload=status_fixture_with_suggestions(
            jobs=[job("job-1", status="running")],
            suggestions=[suggestion_fixture("sugg-1")]))
        m = self.dump_model(base)
        self.assertNotIn("sugg-1", self.ids(m))
        self.assertEqual(self.ids(m), ["job-1"])
        self.assertEqual(m["count"], len(m["records"]))

    def test_search_narrows_suggestions_to_the_matching_rationale(self):
        base = self.serve(payload=status_fixture_with_suggestions(suggestions=[
            suggestion_fixture("sugg-1", rationale="zephyr needs a follow-up"),
            suggestion_fixture("sugg-2", rationale="something unrelated"),
        ]))
        m = self.dump_model(base, "--search", "zephyr")
        self.assertEqual([s["item_id"] for s in m["suggestions"]], ["sugg-1"])


class TestDecidePayload(ModelCase):
    """`--dump-decide`: the POST /decide body, built without being sent."""

    def dump_decide(self, *args, expect=0):
        return self.run_binary("--dump-decide", *args,
                               extra_env=dict(_SUGGEST_DEFAULTS_ENV), expect=expect)

    def test_each_of_the_four_actions_builds_the_three_key_body(self):
        for action in ("confirm", "deny", "go", "snooze"):
            body = json.loads(self.dump_decide("sugg-1", action).stdout)
            self.assertEqual(sorted(body), ["action", "comment", "id"])
            self.assertEqual(body["id"], "sugg-1")
            self.assertEqual(body["action"], action)

    def test_comment_is_present_even_when_empty(self):
        """The route documents `comment` as a key, not an optional one."""
        body = json.loads(self.dump_decide("sugg-1", "confirm").stdout)
        self.assertEqual(body["comment"], "")

    def test_a_comment_is_carried_through_when_given(self):
        body = json.loads(
            self.dump_decide("sugg-1", "snooze", "revisit after standup").stdout)
        self.assertEqual(body["comment"], "revisit after standup")

    def test_an_action_outside_the_four_is_refused_naming_them(self):
        """"accept" is the interesting case: it is a valid /save action, and
        posting it to /decide would be exactly the wrong-vocabulary bug this
        route exists to prevent."""
        for action in ("accept", "yes", ""):
            proc = self.dump_decide("sugg-1", action, expect=1)
            self.assertIn("confirm/deny/go/snooze", proc.stderr)

    def test_an_empty_item_id_is_refused(self):
        self.dump_decide("", "confirm", expect=1)

    def test_the_body_carries_no_saved_at_or_decisions_array(self):
        """Unlike /save's payload, this is not a wholesale-overwrite shape --
        carrying decisions along is exactly what /decide exists to stop."""
        body = json.loads(self.dump_decide("sugg-1", "confirm").stdout)
        self.assertNotIn("saved_at", body)
        self.assertNotIn("decisions", body)


class TestDecideRoundTrip(PassCase):
    """POST /decide, and the POST /save fallback when a Pass has not shipped
    the route yet, through `--post-decide` (a real round trip against the
    fixture Pass, never a real server or port 8811)."""

    def write_decisions(self, decisions, saved_at="2026-09-04T10:00:00.000Z"):
        (self.hub / "decisions.json").write_text(
            json.dumps({"saved_at": saved_at, "decisions": decisions}))

    def post_decide(self, base, item_id, action, expect=0):
        return self.run_binary("--post-decide", item_id, action,
                               extra_env={"QT_PASS_URL": base, **_SUGGEST_DEFAULTS_ENV},
                               expect=expect)

    def test_a_pass_that_accepts_decide_gets_exactly_one_post_with_the_three_key_body(self):
        base = self.serve(payload=status_fixture())
        proc = self.post_decide(base, "sugg-1", "confirm")
        self.assertEqual(json.loads(proc.stdout),
                         {"ok": True, "route": "decided", "fell_back": False})
        posts = self.server.posts_to("/decide")
        self.assertEqual(len(posts), 1, self.server.posts)
        self.assertEqual(posts[0]["body"], {"id": "sugg-1", "action": "confirm",
                                            "comment": ""})
        # The carry-forward must stop once /decide exists.
        self.assertEqual(self.server.posts_to("/save"), [])

    def test_a_404_on_decide_falls_back_to_save(self):
        base = self.serve(payload=status_fixture(), post_codes={"/decide": 404})
        proc = self.post_decide(base, "sugg-1", "confirm")
        self.assertEqual(json.loads(proc.stdout),
                         {"ok": True, "route": "save", "fell_back": True})
        self.assertEqual(len(self.server.posts_to("/decide")), 1)
        save_posts = self.server.posts_to("/save")
        self.assertEqual(len(save_posts), 1, self.server.posts)
        self.assertEqual(sorted(save_posts[0]["body"]), ["decisions", "saved_at"])

    def test_confirm_maps_to_accept_and_deny_maps_to_reject_on_the_fallback(self):
        """The two answers that have honest /save equivalents."""
        base = self.serve(payload=status_fixture(), post_codes={"/decide": 404})
        self.post_decide(base, "sugg-confirm", "confirm")
        self.post_decide(base, "sugg-deny", "deny")
        actions = {p["body"]["decisions"][-1]["id"]: p["body"]["decisions"][-1]["action"]
                  for p in self.server.posts_to("/save")}
        self.assertEqual(actions, {"sugg-confirm": "accept", "sugg-deny": "reject"})

    def test_go_and_snooze_are_refused_rather_than_mistranslated_on_the_fallback(self):
        """Mistranslating a snooze into an accept would file the wrong
        decision, so these two are refused instead of approximated."""
        base = self.serve(payload=status_fixture(), post_codes={"/decide": 404})
        for action in ("go", "snooze"):
            proc = self.post_decide(base, "sugg-1", action, expect=1)
            body = json.loads(proc.stdout)
            self.assertFalse(body["ok"])
            self.assertIn("error", body)
        # The /decide attempt still happened for both; neither ever reached /save.
        self.assertEqual(len(self.server.posts_to("/decide")), 2)
        self.assertEqual(self.server.posts_to("/save"), [])

    def test_fallback_carries_a_pending_decision_for_a_different_item_and_appends_its_own_last(self):
        self.write_decisions([
            {"id": "other-item", "title": "Other", "state": "today",
             "action": "snooze", "comment": ""},
        ])
        base = self.serve(payload=status_fixture(), post_codes={"/decide": 404})
        self.post_decide(base, "sugg-1", "confirm")
        decisions = self.server.posts_to("/save")[0]["body"]["decisions"]
        self.assertEqual([d["id"] for d in decisions], ["other-item", "sugg-1"])
        self.assertEqual(decisions[-1]["action"], "accept")

    def test_the_decide_path_does_not_carry_a_pending_decision_along(self):
        """/decide merges one decision without touching the rest of
        decisions.json -- that is the whole point of the new route, unlike
        /save's wholesale overwrite."""
        self.write_decisions([
            {"id": "other-item", "title": "Other", "state": "today",
             "action": "snooze", "comment": ""},
        ])
        base = self.serve(payload=status_fixture())
        self.post_decide(base, "sugg-1", "confirm")
        self.assertEqual(self.server.posts_to("/save"), [])
        self.assertEqual(self.server.posts_to("/decide")[0]["body"],
                         {"id": "sugg-1", "action": "confirm", "comment": ""})

    def test_a_405_on_decide_falls_back_the_same_way_a_404_does(self):
        base = self.serve(payload=status_fixture(), post_codes={"/decide": 405})
        proc = self.post_decide(base, "sugg-1", "confirm")
        self.assertEqual(json.loads(proc.stdout),
                         {"ok": True, "route": "save", "fell_back": True})
        self.assertEqual(len(self.server.posts_to("/save")), 1)

    def test_a_500_on_decide_is_a_real_failure_and_does_not_fall_back(self):
        """Quietly retrying a refused decision against /save would turn one
        refused decision into a wholesale overwrite."""
        base = self.serve(payload=status_fixture(), post_codes={"/decide": 500})
        proc = self.post_decide(base, "sugg-1", "confirm", expect=1)
        body = json.loads(proc.stdout)
        self.assertFalse(body["ok"])
        self.assertIn("error", body)
        self.assertEqual(self.server.posts_to("/save"), [])

    def test_the_decide_post_carries_no_origin_header(self):
        """serve.py's _origin_blocked() lets a request through only when
        Origin is absent, the same hole every other POST in this suite comes
        in by."""
        base = self.serve(payload=status_fixture())
        self.post_decide(base, "sugg-1", "confirm")
        posts = self.server.posts_to("/decide")
        self.assertEqual(len(posts), 1)
        self.assertNotIn("Origin", posts[0]["headers"])
