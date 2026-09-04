#!/usr/bin/env python3
"""Menu-bar widget: the two feeds, dedup, sections, ordering, and payloads.

Follows this repo's existing test style (see test_hub_feed.py): drive the real
thing as a subprocess against throwaway fixture directories rather than
reimplementing its logic in the test. Here the real thing is the built
QuicktaskStatus binary invoked with `--dump-model`, which runs the same
Feed/Store/MenuModel code the menu draws from and prints the result as JSON.
That keeps the assertions on observable behaviour and means the tests cannot
drift away from what the widget actually shows.

Two more seams get the same treatment. `--dump-capture` and `--dump-decision`
print the POST bodies the widget would send without sending them, because
payload construction is the part of an HTTP client most worth pinning down and
the part least worth a live server to check. And FixturePass stands up a real
loopback server on an ephemeral port, so the /status.json path is exercised end
to end -- transport, parse, join, merge -- and so is the fallback when nothing
answers.

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
    """One /status.json needs_you[] entry. Deliberately thin: the contract
    gives these no resume_url and no report, which is why the widget has to
    join them onto jobs[] by item_id."""
    return {
        "item_id": item_id,
        "title": fields.pop("title", f"title for {item_id}"),
        "state": fields.pop("state", reason),
        "reason": reason,
    }


def status_fixture(jobs=(), needs=(), groups=None, counts=None, pass_url=None):
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
        body = json.dumps(self.owner.post_body).encode()
        self.send_response(self.owner.post_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class FixturePass:
    """A real HTTP server on an ephemeral loopback port, standing in for
    hub/serve.py. Real rather than mocked because the widget's Pass path is a
    URLSession round trip, and the thing most worth proving is that the round
    trip works and that its absence is handled."""

    def __init__(self, payload=None, raw=None, status_code=200,
                 post_body=None, post_code=200):
        self.payload = payload
        self.raw = raw
        self.status_code = status_code
        self.post_body = post_body if post_body is not None else {"ok": True, "id": "cap-1"}
        self.post_code = post_code
        self.gets = []
        self.posts = []
        self._srv = None

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

    def test_a_finished_job_with_no_timestamps_lands_in_done_today(self):
        """A terminal job the Pass is reporting live, with nothing to date it
        by, belongs to today rather than behind the collapsed Earlier."""
        payload = json.loads(REAL_STATUS_SAMPLE)
        payload["needs_you"] = []
        payload["jobs"] = [j for j in payload["jobs"] if j["item_id"] == "done1"]
        base = self.serve(payload=payload)
        m = self.pass_model(base)
        self.assertEqual([s["key"] for s in m["sections"]], ["done_today"])


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
