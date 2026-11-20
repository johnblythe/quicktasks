#!/usr/bin/env python3
"""Menu bar ask field (Q12): the fire's two modes, the receipt and its Undo,
the Ask-again list, and the live line / reason the rows render.

Drives the built widget's exit-before-UI seams against loopback fixture
hubs, exactly like test_asks_rows/test_asks_moves_ui: `--ask-fire` really
performs the field's fire (Run now spawns a *stub* qt through QT_BIN, never
the real one; Ask me first really POSTs /asks and, on a 501/404, really
falls back to /capture), `--ask-again` walks the recent-asks click, and
`--ask-dump-rows` pins the row rendering. Nothing here draws a panel, posts
a real notification, or touches ~/.quicktasks or any live hub file: every
test points QT_DATA / QT_HUB at a temp dir, QT_BIN at a throwaway stub, and
QT_PASS_URL at a fixture.

Skips (rather than fails) when swiftc is missing, like test_menubar_model.
"""
import live_guard  # noqa: F401  # FIRST: sandboxes QT_DATA etc. before anything reads the env

import json
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from asks_harness import AskCase, ask_row, counts_for


# --- the fixture hub ----------------------------------------------------------
#
# AskFixturePass-style, but with the two POST routes the ask field needs kept
# apart: /asks and /capture get their own configurable replies (the shared
# harness keys every non-move POST under one slot, which cannot express
# "501 here, 200 there"). The default /asks reply is 501 with the same words
# the real hub answers today, so the fallback path is exercised against the
# honest fixture by default.

class _FieldHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        owner = self.owner
        url = urlparse(self.path)
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        owner.gets.append({"path": url.path, "query": query})
        if url.path == "/asks.json":
            rows = owner.asks
            if query.get("place"):
                rows = [r for r in rows if r.get("place") == query["place"]]
            return self._send(200, {"v": 1, "rev": owner.rev,
                                    "generated_at": "2026-11-17T10:00:00-05:00",
                                    "counts": counts_for(owner.asks),
                                    "asks": rows})
        return self._send(404, b"not found", "text/plain")

    def do_POST(self):
        owner = self.owner
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        try:
            body = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            body = None
        path = urlparse(self.path).path
        parts = path.strip("/").split("/")
        if parts == ["asks"]:
            owner.asks_posts.append({"path": path, "body": body})
            code, reply = owner.asks_post
            return self._send(code, reply)
        if parts == ["capture"]:
            owner.capture_posts.append({"path": path, "body": body})
            code, reply = owner.capture_post
            return self._send(code, reply)
        if len(parts) == 3 and parts[0] == "asks":
            owner.move_posts.append({"path": path, "id": parts[1],
                                     "move": parts[2], "body": body})
            code, reply = owner.move_replies.get(parts[2], (200, None))
            if reply is None:
                reply = {"ok": True, "ask": ask_row(parts[1], state="done"),
                         "undo": {"token": "tok-1",
                                  "expires_at": "2026-11-17T10:10:00-05:00"},
                         "message": f"{parts[2]} done"}
            return self._send(code, reply)
        return self._send(404, b"not found", "text/plain")


class FieldPass:
    """The hub's ask API plus the two creation routes, on an ephemeral port.

    asks feeds GET /asks.json (a `place` query filters, as the hub's does);
    asks_post is (code, body) for POST /asks -- default 501, the real hub's
    "not built yet" answer; capture_post is the same for POST /capture;
    move_replies maps a move to (code, body-or-None). Every POST is recorded.
    """

    def __init__(self, asks=None, rev="rev-1",
                 asks_post=None, capture_post=None, move_replies=None):
        self.asks = list(asks or [])
        self.rev = rev
        self.asks_post = asks_post or (501, {"ok": False,
                                             "message": "creating an ask is not built yet"})
        self.capture_post = capture_post or (200, {"id": "gate-1"})
        self.move_replies = dict(move_replies or {})
        self.gets = []
        self.asks_posts = []
        self.capture_posts = []
        self.move_posts = []
        self._srv = None

    def start(self):
        handler = type("H", (_FieldHandler,), {"owner": self})
        self._srv = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=self._srv.serve_forever, daemon=True).start()
        return f"http://127.0.0.1:{self._srv.server_address[1]}"

    def stop(self):
        if self._srv is not None:
            self._srv.shutdown()
            self._srv.server_close()
            self._srv = None


# --- the case -----------------------------------------------------------------

class FieldCase(AskCase):
    """A fixture hub with separate creation routes, a stub qt that records
    its argv, and a deterministic fire directory."""

    def setUp(self):
        super().setUp()
        self.fire_dir = self.tmp / "firedir"
        self.fire_dir.mkdir()
        self.argv_log = self.tmp / "qt-argv.log"

    def serve_field(self, **kwargs):
        server = FieldPass(**kwargs)
        base = server.start()
        self.addCleanup(server.stop)
        self.field = server
        return base

    def stub_qt(self):
        """A throwaway executable standing in for qt: one line per argument,
        a blank line per invocation, into $QT_ARGV_LOG. Never the real qt on
        this machine, never anything under ~/.quicktasks."""
        path = self.tmp / "bin" / "qt"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            '#!/bin/sh\n'
            'if [ -n "$QT_ARGV_LOG" ]; then\n'
            '  for a in "$@"; do printf \'%s\\n\' "$a" >> "$QT_ARGV_LOG"; done\n'
            '  printf \'\\n\' >> "$QT_ARGV_LOG"\n'
            'fi\n'
            'exit 0\n')
        path.chmod(0o755)
        return str(path)

    def qt_env(self, extra=None):
        env = {"QT_BIN": self.stub_qt(),
               "QT_ARGV_LOG": str(self.argv_log),
               "QT_MENUBAR_FIRE_DIR": str(self.fire_dir)}
        env.update(extra or {})
        return env

    def fire(self, text, *extra, base="", expect=0, extra_env=None):
        return self.seam("--ask-fire", text, *extra, pass_url=base,
                         expect=expect, extra_env=extra_env)

    def qt_invocations(self, count=1, timeout=5.0):
        """The stub qt's argv log, one array per invocation, polled until the
        expected number of invocations has landed (a fire returns before its
        child writes; a stop waits, but the poll makes no assumption)."""
        deadline = time.monotonic() + timeout
        text = ""
        while time.monotonic() < deadline:
            if self.argv_log.is_file():
                text = self.argv_log.read_text()
                if len([g for g in text.split("\n\n") if g.strip()]) >= count:
                    break
            time.sleep(0.05)
        return [g.split("\n") for g in text.split("\n\n") if g.strip()]


class RowsCase(AskCase):
    """The rows the field's board draws, via the shared harness fixture."""

    def rows(self, base="", *extra, expect=0):
        return self.seam("--ask-dump-rows", *extra, pass_url=base, expect=expect)

    def row_by_id(self, model, ask_id):
        for section in model["sections"]:
            for row in section["rows"]:
                if row["id"] == ask_id:
                    return row
        raise AssertionError(f"{ask_id} not in {[r['id'] for s in model['sections'] for r in s['rows']]}")


# --- ⏎ Run now ----------------------------------------------------------------

class TestRunNowFiresQt(FieldCase):
    def test_run_now_fires_qt_with_the_field_argv(self):
        """⏎ Run now is exactly today's fire: qt, `--in <dir> <words>`, the
        directory the chip (or a typed prefix) resolved. The stub qt records
        the real spawn's argv; the receipt is the plan's fixed line."""
        base = self.serve_field()
        out = self.fire("fix the flaky test", "--ask-mode", "run",
                        base=base, extra_env=self.qt_env())
        self.assertTrue(out["ok"])
        self.assertEqual(out["dir"], str(self.fire_dir))
        self.assertEqual(self.qt_invocations(1),
                         [["--in", str(self.fire_dir), "fix the flaky test"]])

    def test_the_receipt_is_the_plans_fixed_words(self):
        base = self.serve_field()
        out = self.fire("fix the flaky test", "--ask-mode", "run",
                        base=base, extra_env=self.qt_env())
        receipt = out["receipt"]
        self.assertEqual(receipt["kind"], "run")
        self.assertEqual(receipt["line"],
                         "Got it. Running. The answer will come to you here.")
        self.assertEqual(receipt["words"], "fix the flaky test")
        self.assertTrue(receipt["undoable"])
        self.assertEqual(receipt["undo_window_s"], 600)

    def test_a_typed_prefix_fires_in_that_directory(self):
        other = self.tmp / "otherdir"
        other.mkdir()
        base = self.serve_field()
        out = self.fire(f"--in {other} fix it", "--ask-mode", "run",
                        base=base, extra_env=self.qt_env())
        self.assertEqual(out["dir"], str(other))
        self.assertEqual(out["dir_source"], "prefix")
        self.assertEqual(self.qt_invocations(1),
                         [["--in", str(other), "fix it"]])
        self.assertEqual(out["receipt"]["words"], "fix it")

    def test_the_model_chip_rides_the_fire_as_m(self):
        """--ask-model stands in for the chip's choice: one `-m <name>`
        between --in and the words, exactly the argv the chip produces."""
        base = self.serve_field()
        out = self.fire("route this one on kimi", "--ask-mode", "run",
                        "--ask-model", "kimi-k3.1-pro",
                        base=base, extra_env=self.qt_env())
        self.assertTrue(out["ok"])
        self.assertEqual(out["model"], "kimi-k3.1-pro")
        self.assertEqual(self.qt_invocations(1),
                         [["--in", str(self.fire_dir),
                           "-m", "kimi-k3.1-pro", "route this one on kimi"]])

    def test_a_default_fire_carries_no_model_flag(self):
        base = self.serve_field()
        out = self.fire("no chip choice made", "--ask-mode", "run",
                        base=base, extra_env=self.qt_env())
        self.assertNotIn("model", out)
        argv, = self.qt_invocations(1)
        self.assertNotIn("-m", argv)

    def test_an_unknown_model_name_reads_as_default(self):
        """A stored name this build does not know (a newer chip's entry)
        must not fire a -m qt cannot expand -- it reads as Default."""
        base = self.serve_field()
        out = self.fire("mystery chip state", "--ask-mode", "run",
                        "--ask-model", "glm-9.9-not-yet",
                        base=base, extra_env=self.qt_env())
        self.assertNotIn("model", out)
        argv, = self.qt_invocations(1)
        self.assertNotIn("-m", argv)

    def test_a_refused_fire_reports_and_leaves_no_receipt(self):
        """QT_BIN at a directory passes the executable check and then throws
        on Process.run -- the same deterministic refusal test_menubar_model
        uses, so no real qt is ever invoked."""
        base = self.serve_field()
        out = self.fire("fix the flaky test", "--ask-mode", "run", base=base,
                        expect=1, extra_env={"QT_BIN": str(self.tmp),
                                             "QT_MENUBAR_FIRE_DIR": str(self.fire_dir)})
        self.assertFalse(out["ok"])
        self.assertTrue(out["error"].startswith("could not run qt:"), out["error"])
        self.assertNotIn("receipt", out)


# --- ⌘⏎ Ask me first ----------------------------------------------------------

class TestAskFirstPosts(FieldCase):
    def test_posts_the_contract_body_and_leaves_the_receipt(self):
        created = ask_row("hub-gate-9", state="wants_ok")
        base = self.serve_field(asks_post=(201, {"ok": True, "ask": created}))
        out = self.fire("who owns the billing contact", "--ask-mode", "ask_first",
                        base=base, extra_env=self.qt_env())
        self.assertTrue(out["ok"])
        self.assertEqual(out["route"], "asks")
        self.assertEqual(out["ask_id"], "hub-gate-9")
        self.assertEqual(len(self.field.asks_posts), 1)
        self.assertEqual(self.field.asks_posts[0]["body"],
                         {"text": "who owns the billing contact",
                          "mode": "ask_first",
                          "door": "typed",
                          "dir": str(self.fire_dir)})
        # The route that exists is the one that took it: no capture fallback.
        self.assertEqual(self.field.capture_posts, [])
        receipt = out["receipt"]
        self.assertEqual(receipt["kind"], "ask_first")
        self.assertEqual(receipt["line"], "Got it. It waits for your OK.")
        self.assertEqual(receipt["ask_id"], "hub-gate-9")

    def test_the_model_chip_rides_ask_first_too(self):
        """The chip's choice is part of the fire, whichever mode: the
        ask-first body carries it as `model` (plan 1.6), so the gate item
        records what it should later run on."""
        created = ask_row("hub-gate-m", state="wants_ok")
        base = self.serve_field(asks_post=(201, {"ok": True, "ask": created}))
        out = self.fire("run this on the flash model", "--ask-mode", "ask_first",
                        "--ask-model", "glm-5p3-flash",
                        base=base, extra_env=self.qt_env())
        self.assertTrue(out["ok"])
        self.assertEqual(self.field.asks_posts[0]["body"],
                         {"text": "run this on the flash model",
                          "mode": "ask_first",
                          "door": "typed",
                          "dir": str(self.fire_dir),
                          "model": "glm-5p3-flash"})

    def test_a_typed_prefix_strips_and_carries_the_directory(self):
        other = self.tmp / "otherdir"
        other.mkdir()
        created = ask_row("hub-gate-9", state="wants_ok")
        base = self.serve_field(asks_post=(201, {"ok": True, "ask": created}))
        out = self.fire(f"--in {other} who owns billing", "--ask-mode", "ask_first",
                        base=base, extra_env=self.qt_env())
        self.assertEqual(out["dir_source"], "prefix")
        self.assertEqual(self.field.asks_posts[0]["body"]["text"], "who owns billing")
        self.assertEqual(self.field.asks_posts[0]["body"]["dir"], str(other))

    def test_a_501_hub_falls_back_to_capture_exactly_as_today(self):
        """The default fixture answers 501 with the real hub's own words --
        POST /asks creation is not built yet (H12) -- so the field takes
        today's To-Pass path: the raw unstripped text to /capture, and the
        same landing line that path has always shown."""
        base = self.serve_field()
        out = self.fire("write the release notes", "--ask-mode", "ask_first",
                        base=base, extra_env=self.qt_env())
        self.assertTrue(out["ok"])
        self.assertEqual(out["route"], "capture")
        self.assertEqual(out["captured_id"], "gate-1")
        self.assertEqual(len(self.field.asks_posts), 1)
        self.assertEqual(self.field.asks_posts[0]["body"]["mode"], "ask_first")
        self.assertEqual(len(self.field.capture_posts), 1)
        self.assertEqual(self.field.capture_posts[0]["body"],
                         {"text": "write the release notes", "source": "menubar"})
        self.assertEqual(out["fallback_line"], "On the Pass: write the release notes")

    def test_a_404_hub_falls_back_the_same_way(self):
        base = self.serve_field(asks_post=(404, b"not found"))
        out = self.fire("write the release notes", "--ask-mode", "ask_first",
                        base=base, extra_env=self.qt_env())
        self.assertEqual(out["route"], "capture")
        self.assertEqual(len(self.field.capture_posts), 1)

    def test_a_real_failure_does_not_fall_back(self):
        """Only 501/404 mean 'no such route'. A 500 is the hub failing, and
        quietly re-posting it to /capture would turn one refused ask into a
        silently different one."""
        base = self.serve_field(asks_post=(500, {"ok": False, "message": "boom"}))
        out = self.fire("write the release notes", "--ask-mode", "ask_first",
                        base=base, expect=1, extra_env=self.qt_env())
        self.assertFalse(out["ok"])
        self.assertIn("500", out["error"])
        self.assertEqual(self.field.capture_posts, [])


# --- the receipt's Undo -------------------------------------------------------

class TestReceiptUndoStops(FieldCase):
    def _working_ask(self):
        return ask_row("qt-261117-104500-fix-the", state="working",
                       words="fix the flaky test", created_at="2026-11-17T10:45:00-05:00")

    def test_undo_stops_the_fired_ask_and_drops_it(self):
        """Undo = `qt stop` + drop, within the undo window: the fired ask is
        resolved off the board by its words, qt is invoked with `stop <tid>`
        (the ask id minus its `qt-` prefix), and the drop move is POSTed."""
        ask = self._working_ask()
        base = self.serve_field(asks=[ask])
        out = self.fire("fix the flaky test", "--ask-mode", "run", "--ask-undo",
                        base=base, extra_env=self.qt_env())
        self.assertTrue(out["ok"])
        undo = out["undo"]
        self.assertTrue(undo["ok"])
        self.assertEqual(undo["id"], "qt-261117-104500-fix-the")
        self.assertEqual(undo["qt_task_id"], "261117-104500-fix-the")
        self.assertTrue(undo["stopped"])
        self.assertTrue(undo["dropped"])
        # Both qt invocations, order-independent: the fire returns without
        # waiting for its child, so which stub appends to the log first is
        # the scheduler's business, not the field's.
        self.assertEqual(
            sorted(self.qt_invocations(2)),
            sorted([["--in", str(self.fire_dir), "fix the flaky test"],
                    ["stop", "261117-104500-fix-the"]]))
        drops = [p for p in self.field.move_posts if p["move"] == "drop"]
        self.assertEqual(len(drops), 1)
        self.assertEqual(drops[0]["id"], "qt-261117-104500-fix-the")
        self.assertEqual(drops[0]["body"], {})

    def test_undo_after_the_window_refuses(self):
        """The receipt's Undo lives for the undo window (the hub's 600 s
        default), no longer -- an aged receipt refuses rather than stopping
        an ask from some other, later fire."""
        ask = self._working_ask()
        base = self.serve_field(asks=[ask])
        out = self.fire("fix the flaky test", "--ask-mode", "run",
                        "--ask-undo", "--ask-aged", "700",
                        base=base, extra_env=self.qt_env())
        self.assertTrue(out["ok"])
        self.assertFalse(out["receipt"]["undoable"])
        self.assertFalse(out["undo"]["ok"])
        self.assertTrue(out["undo"]["expired"])
        self.assertEqual(sorted(self.qt_invocations(1)),
                         sorted([["--in", str(self.fire_dir), "fix the flaky test"]]))
        self.assertEqual([p for p in self.field.move_posts if p["move"] == "drop"], [])

    def test_ask_first_undo_drops_without_stopping(self):
        """An Ask-me-first ask never ran, so its Undo is only the drop --
        nothing is spawned, the gate item is filed away."""
        created = ask_row("hub-gate-9", state="wants_ok")
        base = self.serve_field(asks=[created],
                                asks_post=(201, {"ok": True, "ask": created}))
        out = self.fire("who owns the billing contact", "--ask-mode", "ask_first",
                        "--ask-undo", base=base, extra_env=self.qt_env())
        self.assertTrue(out["undo"]["ok"])
        self.assertFalse(undo_stopped(out["undo"]), out["undo"])
        self.assertTrue(out["undo"]["dropped"])
        # qt was never invoked at all: no fire, no stop.
        self.assertEqual(self.qt_invocations(0), [])
        drops = [p for p in self.field.move_posts if p["move"] == "drop"]
        self.assertEqual(drops[0]["id"], "hub-gate-9")


def undo_stopped(undo):
    """The seam omits/states `stopped` as a bool; a missing key (an ask the
    board cannot see running) reads as not stopped, same as the view."""
    return bool(undo.get("stopped"))


# --- the live line and the reason --------------------------------------------

class TestNowLineRendered(RowsCase):
    def test_a_working_row_renders_its_live_line(self):
        run = ask_row("qt-run", state="working", now_line="searching Slack")
        base = self.serve(asks=[run])
        row = self.row_by_id(self.rows(base), "qt-run")
        self.assertEqual(row["now_line"], "searching Slack")
        # `lines` is what the row draws under the title, in draw order.
        self.assertEqual(row["lines"][0], "searching Slack")

    def test_a_finished_row_keeps_quiet_about_a_stale_line(self):
        """now_line belongs to working rows; a hub sending one on a finished
        ask is speaking ahead of its own table, and the row says nothing."""
        done = ask_row("qt-done", state="answer", unseen=False, now_line="stale line")
        base = self.serve(asks=[done])
        row = self.row_by_id(self.rows(base), "qt-done")
        self.assertIsNone(row["now_line"])
        self.assertNotIn("stale line", row["lines"])


class TestReasonRendered(RowsCase):
    def test_a_failed_row_renders_the_hubs_reason(self):
        failed = ask_row("qt-fail", state="failed",
                         reason="Ran out of time after 30 minutes.")
        base = self.serve(asks=[failed])
        row = self.row_by_id(self.rows(base), "qt-fail")
        self.assertEqual(row["reason"], "Ran out of time after 30 minutes.")
        self.assertIn("Ran out of time after 30 minutes.", row["lines"])

    def test_reason_is_for_failed_rows_only(self):
        working = ask_row("qt-run", state="working", reason="not a verdict")
        base = self.serve(asks=[working])
        row = self.row_by_id(self.rows(base), "qt-run")
        self.assertIsNone(row["reason"])
        self.assertNotIn("not a verdict", row["lines"])

    def test_a_failed_row_without_a_reason_renders_none(self):
        failed = ask_row("qt-fail", state="failed", reason=None)
        base = self.serve(asks=[failed])
        row = self.row_by_id(self.rows(base), "qt-fail")
        self.assertIsNone(row["reason"])
        # Its one sub-line is the last-attempt facts, not a made-up reason.
        self.assertEqual(row["lines"], [row["last_attempt"]])


# --- Ask again ----------------------------------------------------------------

class TestAskAgain(FieldCase):
    def test_the_list_is_the_hubs_done_pages(self):
        """Ask again reads the hub's own done pages -- `place=done`, the
        contract's way to page newest first -- not a local guess."""
        recents = [ask_row("qt-261115-091300-deploy-bot", state="done",
                           words="what changed in the deploy bot"),
                   ask_row("qt-261114-180000-oncall-pay", state="done",
                           words="who is on call for payments tonight")]
        base = self.serve_field(asks=recents)
        out = self.seam("--ask-again", pass_url=base)
        self.assertTrue(out["ok"])
        self.assertEqual([r["id"] for r in out["recent"]],
                         ["qt-261115-091300-deploy-bot", "qt-261114-180000-oncall-pay"])
        asks_lists = [g for g in self.field.gets if g["path"] == "/asks.json"]
        self.assertEqual(len(asks_lists), 1)
        self.assertEqual(asks_lists[0]["query"].get("place"), "done")

    def test_a_click_loads_the_words_and_describes_the_refire(self):
        """Clicking a recent ask re-fires its words: they land in the field,
        and a fire of them resolves through the same FireResolve.describe
        every fire describes by -- argv and all, in either mode."""
        recents = [ask_row("qt-261115-091300-deploy-bot", state="done",
                           words="what changed in the deploy bot")]
        base = self.serve_field(asks=recents)
        out = self.seam("--ask-again", "deploy", pass_url=base,
                        extra_env={"QT_MENUBAR_FIRE_DIR": str(self.fire_dir)})
        picked = out["picked"]
        self.assertEqual(picked["id"], "qt-261115-091300-deploy-bot")
        self.assertEqual(picked["draft"], "what changed in the deploy bot")
        self.assertEqual(picked["run"]["argv"],
                         ["--in", str(self.fire_dir), "what changed in the deploy bot"])
        # The second mode's fallback leg is today's capture body, verbatim.
        self.assertEqual(picked["ask_first_fallback"]["mode"], "pass")
        self.assertEqual(picked["ask_first_fallback"]["text"],
                         "what changed in the deploy bot")

    def test_no_hub_means_no_ask_again(self):
        """The file fallback has no done-list endpoint; the seam refuses
        rather than inventing a recency list."""
        self.seam("--ask-again", pass_url="", expect=2)


if __name__ == "__main__":
    unittest.main()
