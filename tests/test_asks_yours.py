#!/usr/bin/env python3
"""Menu bar asks, slice 5 (Q11): the Yours today section, the ⌥⏎ Remind me
picker, ⌘F find across every ask, and ⌘D's desk.

Drives the built widget's exit-before-UI seams against a loopback fixture
hub, exactly like test_asks_rows/test_asks_moves_ui/test_asks_field:
`--ask-dump-rows` pins the yours section the menu draws, `--ask-remind`
really performs the ⌥⏎ picker's write (POST /asks mode "remind" for the
field, the `remind` move for a row), `--ask-find` really performs ⌘F's
GET /asks/search, and `--ask-desk` resolves ⌘D's target -- printed, never
opened, because a test must not put anything on screen. Nothing here draws
a panel, posts a real notification, or touches ~/.quicktasks or any live
hub file: every test points QT_DATA / QT_HUB at a temp dir and QT_PASS_URL
at a fixture.

Skips (rather than fails) when swiftc is missing, like test_menubar_model.
"""
import live_guard  # noqa: F401  # FIRST: sandboxes QT_DATA etc. before anything reads the env

import json
import threading
import unittest
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from asks_harness import AskCase, ask_row, counts_for, status_fixture


# --- the fixture hub ----------------------------------------------------------
#
# AskFixturePass-style, but with the routes slice 5 needs that the shared
# harness has no slot for: GET /asks/search (H11) and POST /asks (H12 --
# the default reply is the 501 a hub that has not built creation sends, so
# the graceful-degradation paths run against the honest fixture by default).

class _YoursHandler(BaseHTTPRequestHandler):
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
        if url.path == "/asks/search":
            # H11's contract: every ask ever, terms ANDed, row + {match,
            # snippet}. The pool is fixture-supplied so done and archived
            # asks -- invisible to /asks.json -- can be found here.
            if owner.search_code != 200:
                return self._send(owner.search_code,
                                  {"ok": False, "message": "search is off"})
            terms = (query.get("q") or "").lower().split()
            hits = []
            for row, match, snippet in owner.search_pool:
                hay = " ".join([row.get("title", ""), row.get("words", ""),
                                snippet or ""]).lower()
                if all(t in hay for t in terms):
                    hit = dict(row)
                    hit["match"] = match
                    hit["snippet"] = snippet
                    hits.append(hit)
            return self._send(200, {"asks": hits})
        if url.path.startswith("/asks/") and url.path.endswith(".json"):
            ask_id = url.path[len("/asks/"):-len(".json")]
            if ask_id in owner.threads:
                return self._send(200, owner.threads[ask_id])
            return self._send(404, b"unknown ask", "text/plain")
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
        if len(parts) == 3 and parts[0] == "asks":
            owner.move_posts.append({"path": path, "id": parts[1],
                                     "move": parts[2], "body": body})
            code, reply = owner.move_replies.get(parts[2], (200, None))
            if reply is None:
                reply = {"ok": True, "ask": ask_row(parts[1], state="yours"),
                         "undo": {"token": "tok-1",
                                  "expires_at": "2026-11-17T11:00:00-05:00"},
                         "message": f"{parts[2]} done"}
            return self._send(code, reply)
        return self._send(404, b"not found", "text/plain")


class YoursPass:
    """The hub's ask API plus the slice-5 routes, on an ephemeral port.

    asks feeds GET /asks.json; search_pool is [(row, match, snippet)] for
    GET /asks/search (default: the asks themselves, matched in the words);
    asks_post is (code, body) for POST /asks -- default 501, the real hub's
    "not built yet" answer until H12 lands; move_replies maps a move to
    (code, body-or-None). Every request is recorded.
    """

    def __init__(self, asks=None, threads=None, rev="rev-1",
                 search_pool=None, search_code=200,
                 asks_post=None, move_replies=None):
        self.asks = list(asks or [])
        self.threads = dict(threads or {})
        self.rev = rev
        self.search_pool = list(search_pool or []) or [
            (row, "words", None) for row in self.asks]
        self.search_code = search_code
        self.asks_post = asks_post or (501, {"ok": False,
                                             "message": "creating an ask is not built yet"})
        self.move_replies = dict(move_replies or {})
        self.gets = []
        self.posts = []
        self.asks_posts = []
        self.move_posts = []
        self._srv = None

    def start(self):
        handler = type("H", (_YoursHandler,), {"owner": self})
        self._srv = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=self._srv.serve_forever, daemon=True).start()
        return f"http://127.0.0.1:{self._srv.server_address[1]}"

    def stop(self):
        if self._srv is not None:
            self._srv.shutdown()
            self._srv.server_close()
            self._srv = None


# --- the case -----------------------------------------------------------------

class YoursCase(AskCase):
    """A fixture hub with the slice-5 routes, and a deterministic fire
    directory so POST /asks bodies carry a dir the test can name."""

    def setUp(self):
        super().setUp()
        self.fire_dir = self.tmp / "firedir"
        self.fire_dir.mkdir()

    def serve_yours(self, **kwargs):
        server = YoursPass(**kwargs)
        base = server.start()
        self.addCleanup(server.stop)
        self.yours = server
        return base

    def fire_env(self, extra=None):
        env = {"QT_MENUBAR_FIRE_DIR": str(self.fire_dir)}
        env.update(extra or {})
        return env

    def rows(self, base="", *extra, expect=0, extra_env=None):
        return self.seam("--ask-dump-rows", *extra, pass_url=base,
                         expect=expect, extra_env=extra_env)

    def remind(self, *extra, base="", expect=0, extra_env=None):
        return self.seam("--ask-remind", *extra, pass_url=base,
                         expect=expect, extra_env=extra_env)


# --- Yours today ---------------------------------------------------------------

class TestYoursSection(YoursCase):
    def test_yours_rows_get_their_own_section_with_title_and_time(self):
        """The plan's section: label, count, and one row per yours-place ask
        -- title, and the time (the reminder when one is set, the age
        otherwise). The three action sections keep their Q3 shape: the
        yours row is surfaced, not re-bucketed into them."""
        yours = ask_row("hub-yours-1", state="yours",
                        title="Pay the contractor",
                        remind_at="2026-11-17T15:00:00-05:00")
        board = [ask_row("qt-new", state="answer", unseen=True),
                 ask_row("qt-fail", state="failed"),
                 ask_row("qt-run", state="working")]
        base = self.serve_yours(asks=[yours] + board)
        model = self.rows(base)
        # The action sections are exactly Q3's, without the yours row.
        self.assertEqual([s["key"] for s in model["sections"]],
                         ["new_for_you", "needs_you", "working"])
        drawn = [i for s in model["sections"] for i in s["ids"]]
        self.assertNotIn("hub-yours-1", drawn)
        # The yours section: its own label, its own rows.
        self.assertEqual(model["yours"]["label"], "Yours today")
        self.assertEqual(model["yours"]["count"], 1)
        row = model["yours"]["rows"][0]
        self.assertEqual(row["id"], "hub-yours-1")
        self.assertEqual(row["title"], "Pay the contractor")
        self.assertEqual(row["time"], "3:00 PM")
        self.assertEqual(row["remind_line"], "Reminds you at 3:00 PM")
        self.assertTrue(row["open_url"].endswith("/ask/hub-yours-1"))

    def test_a_yours_row_without_a_reminder_shows_its_age(self):
        yours = ask_row("hub-yours-2", state="yours", remind_at=None,
                        updated_at="2026-11-17T08:00:00-05:00")
        base = self.serve_yours(asks=[yours])
        row = self.rows(base)["yours"]["rows"][0]
        self.assertIsNone(row["remind_line"])
        self.assertTrue(row["time"])  # the coarse age, not a made-up time

    def test_the_soonest_reminder_leads_the_section(self):
        later = ask_row("hub-yours-later", state="yours",
                        remind_at="2026-11-17T15:00:00-05:00")
        sooner = ask_row("hub-yours-sooner", state="yours",
                         remind_at="2026-11-17T09:00:00-05:00")
        unreminded = ask_row("hub-yours-plain", state="yours", remind_at=None)
        base = self.serve_yours(asks=[later, unreminded, sooner])
        ids = [r["id"] for r in self.rows(base)["yours"]["rows"]]
        self.assertEqual(ids, ["hub-yours-sooner", "hub-yours-later",
                               "hub-yours-plain"])

    def test_buttons_off_the_hubs_moves_list(self):
        """Done, Remind, Drop -- and Run only when the hub says it can --
        gated on the row's own `moves`, exactly the way the action rows'
        buttons are. Remind is a text move whose typed time travels under
        `at` (contract 1.6), not the prompt/text keys."""
        plain = ask_row("hub-yours-1", state="yours")
        runnable = ask_row("hub-yours-2", state="yours", can_run=True)
        base = self.serve_yours(asks=[plain, runnable])
        rows = {r["id"]: r for r in self.rows(base)["yours"]["rows"]}
        self.assertEqual(
            [(b["title"], b["key"]) for b in rows["hub-yours-1"]["buttons"]],
            [("Done", "e"), ("Remind me\u2026", "r"), ("Drop", "d")])
        remind = next(b for b in rows["hub-yours-1"]["buttons"]
                      if b["move"] == "remind")
        self.assertTrue(remind["text_input"])
        self.assertEqual(remind["body_key"], "at")
        self.assertEqual(
            [b["move"] for b in rows["hub-yours-2"]["buttons"]],
            ["done", "remind", "run", "drop"])
        # A row whose hub offers nothing (the file fallback's rows carry no
        # moves) draws no write it cannot honour.
        bare = ask_row("hub-yours-3", state="yours", moves=[])
        base = self.serve_yours(asks=[bare])
        self.assertEqual(self.rows(base)["yours"]["rows"][0]["buttons"], [])

    def test_the_footer_stub_is_unchanged(self):
        base = self.serve_yours(asks=[ask_row("hub-yours-1", state="yours")])
        model = self.rows(base)
        self.assertEqual(model["footer"], "Find any ask \u2318F / Open the desk \u2318D")
        self.assertEqual(model["yours"]["count"], 1)

    def test_a_hub_without_the_ask_api_has_no_yours_section(self):
        base = self.serve(list_code=404,
                          status_payload=status_fixture())
        model = self.rows(base)
        self.assertIsNone(model["yours"])  # the section is the ask menu's


# --- ⌥⏎ Remind me instead ------------------------------------------------------

class TestRemindPosts(YoursCase):
    def test_the_picker_posts_the_contract_body(self):
        """⌥⏎ is the fire's third mode: POST /asks with the typed words
        (prefix stripped), mode "remind", the door, the resolved directory,
        and the parsed remind_at. 201 creates the to-do; the receipt line
        names the time."""
        created = ask_row("hub-yours-9", state="yours")
        base = self.serve_yours(asks_post=(201, {"ok": True, "ask": created}))
        out = self.remind("pay the contractor", "--ask-at", "3:30 PM",
                          base=base, extra_env=self.fire_env())
        self.assertTrue(out["ok"])
        self.assertEqual(out["mode"], "remind")
        self.assertEqual(out["at_text"], "3:30 PM")
        self.assertEqual(out["ask_id"], "hub-yours-9")
        self.assertEqual(len(self.yours.asks_posts), 1)
        self.assertEqual(self.yours.asks_posts[0]["body"],
                         {"text": "pay the contractor", "mode": "remind",
                          "door": "typed", "dir": str(self.fire_dir),
                          "remind_at": out["remind_at"]})
        # The parsed time: 3:30 PM, today's or tomorrow's, never a guess the
        # hub cannot read.
        at = datetime.fromisoformat(out["remind_at"])
        self.assertEqual((at.hour, at.minute), (15, 30))
        self.assertGreaterEqual(at.date(), datetime.now().date())

    def test_a_typed_prefix_strips_and_carries_the_directory(self):
        other = self.tmp / "otherdir"
        other.mkdir()
        created = ask_row("hub-yours-9", state="yours")
        base = self.serve_yours(asks_post=(201, {"ok": True, "ask": created}))
        out = self.remind(f"--in {other} pay the contractor",
                          "--ask-at", "in 2h", base=base,
                          extra_env=self.fire_env())
        self.assertEqual(out["dir_source"], "prefix")
        self.assertEqual(out["dir"], str(other))
        self.assertEqual(self.yours.asks_posts[0]["body"]["text"],
                         "pay the contractor")
        self.assertEqual(self.yours.asks_posts[0]["body"]["dir"], str(other))

    def test_an_empty_picker_defaults_to_one_hour_from_now(self):
        created = ask_row("hub-yours-9", state="yours")
        base = self.serve_yours(asks_post=(201, {"ok": True, "ask": created}))
        out = self.remind("pay the contractor", base=base,
                          extra_env=self.fire_env())
        self.assertEqual(out["spec"], "in 1 hour")
        at = datetime.fromisoformat(out["remind_at"])
        delta = (at - datetime.now().astimezone()).total_seconds()
        self.assertGreater(delta, 3500)
        self.assertLess(delta, 3700)

    def test_a_501_hub_answers_in_its_own_words_no_dead_button(self):
        """The default fixture answers 501 with the real hub's own words --
        POST /asks creation is H12's, not built yet -- and the picker shows
        exactly that message rather than falling back to /capture: a
        silently captured item is not a reminder."""
        base = self.serve_yours()
        out = self.remind("pay the contractor", "--ask-at", "in 2h",
                          base=base, expect=1, extra_env=self.fire_env())
        self.assertFalse(out["ok"])
        self.assertEqual(out["kind"], "not_built")
        self.assertEqual(out["message"], "creating an ask is not built yet")
        self.assertEqual(len(self.yours.asks_posts), 1)
        self.assertEqual(self.yours.move_posts, [])

    def test_an_unreadable_time_refuses_rather_than_guessing(self):
        base = self.serve_yours()
        self.remind("pay the contractor", "--ask-at", "someday maybe",
                    base=base, expect=2, extra_env=self.fire_env())
        self.assertEqual(self.yours.asks_posts, [])

    def test_the_row_knob_posts_the_remind_move(self):
        """A yours row's Remind: the `remind` move with `{"at": ...}` on the
        row's own id, landing the same verdict line every move leaves."""
        yours = ask_row("hub-yours-1", state="yours")
        base = self.serve_yours(asks=[yours])
        out = self.remind("--ask-row", "hub-yours-1", "--ask-at", "9a",
                          base=base)
        self.assertTrue(out["ok"])
        self.assertEqual(out["id"], "hub-yours-1")
        self.assertEqual(out["at_text"], "9:00 AM")
        self.assertEqual(out["line"], "Remind \u00B7 Z to undo")
        reminds = [p for p in self.yours.move_posts if p["move"] == "remind"]
        self.assertEqual(len(reminds), 1)
        self.assertEqual(reminds[0]["id"], "hub-yours-1")
        self.assertEqual(reminds[0]["body"], {"at": out["remind_at"]})
        # The field's route was never touched: the row knob is the move.
        self.assertEqual(self.yours.asks_posts, [])

    def test_the_row_knob_clears_with_at_null(self):
        yours = ask_row("hub-yours-1", state="yours",
                        remind_at="2026-11-17T15:00:00-05:00")
        base = self.serve_yours(asks=[yours])
        out = self.remind("--ask-row", "hub-yours-1", "--ask-at", "none",
                          base=base)
        self.assertTrue(out["ok"])
        self.assertTrue(out["clears"])
        reminds = [p for p in self.yours.move_posts if p["move"] == "remind"]
        self.assertEqual(reminds[0]["body"], {"at": None})

    def test_no_hub_means_no_reminder(self):
        """The file fallback has no POST /asks; the seam refuses rather than
        inventing a to-do with nowhere to hold it."""
        self.remind("pay the contractor", expect=2)


# --- ⌘F find -------------------------------------------------------------------

class TestFindResults(YoursCase):
    def _pool(self):
        # Every ask ever: a done ask the list never shows, plus a live one.
        old = ask_row("qt-261115-091300-renewal", state="done",
                      words="who owns the billing contact for the renewal",
                      answer_excerpt="Procurement owns it. Renewal is Jan 14.")
        live = ask_row("qt-billing-live", state="answer", unseen=True,
                       words="billing contact for the GitHub renewal")
        return old, live

    def test_find_asks_the_hub_and_prints_rows(self):
        """⌘F is GET /asks/search: one request, terms ANDed, and results
        that are rows -- each with its own address, the where of the match,
        and the snippet -- including asks the list never shows."""
        old, live = self._pool()
        base = self.serve_yours(asks=[live], search_pool=[
            (old, "answer", "Procurement owns it. Renewal is Jan 14."),
            (live, "words", None)])
        out = self.seam("--ask-find", "billing renewal", pass_url=base)
        self.assertTrue(out["ok"])
        self.assertEqual(out["count"], 2)
        ids = [r["id"] for r in out["results"]]
        self.assertIn("qt-261115-091300-renewal", ids)  # done, still found
        by_id = {r["id"]: r for r in out["results"]}
        self.assertEqual(by_id["qt-261115-091300-renewal"]["match_label"],
                         "in the answer")
        self.assertIn("Renewal is Jan 14",
                      by_id["qt-261115-091300-renewal"]["snippet"])
        for hit in out["results"]:
            self.assertTrue(hit["open_url"].endswith(f"/ask/{hit['id']}"))
        # The one request the field's fetch makes.
        searches = [g for g in self.yours.gets if g["path"] == "/asks/search"]
        self.assertEqual(len(searches), 1)
        self.assertEqual(searches[0]["query"].get("q"), "billing renewal")

    def test_results_open_in_the_row(self):
        """A found ask is a row: the eye reads its answer in place -- the
        same thread fetch, and `seen` for an unseen one, exactly as
        expanding a section row does."""
        old, live = self._pool()
        threads = {"qt-billing-live": dict(live,
                                           answer_text="Procurement owns it.\n\nRenewal is Jan 14.",
                                           answer_truncated=False,
                                           timeline=[], runs=[])}
        base = self.serve_yours(asks=[live], threads=threads, search_pool=[
            (live, "words", None)])
        out = self.seam("--ask-find", "billing", "--ask-expand", "billing-live",
                        pass_url=base)
        exp = out["expanded"]
        self.assertTrue(exp["from_thread"])
        self.assertIn("Renewal is Jan 14", exp["answer_text"])
        self.assertTrue(exp["post_seen"])
        self.assertTrue(exp["seen_ok"])
        seen = [p for p in self.yours.move_posts if p["move"] == "seen"]
        self.assertEqual(seen, [{"path": "/asks/qt-billing-live/seen",
                                 "id": "qt-billing-live", "move": "seen",
                                 "body": {}}])

    def test_no_match_is_an_honest_zero_not_an_error(self):
        _, live = self._pool()
        base = self.serve_yours(asks=[live])
        out = self.seam("--ask-find", "nothing matches this", pass_url=base)
        self.assertTrue(out["ok"])
        self.assertEqual(out["count"], 0)
        self.assertEqual(out["results"], [])

    def test_a_refused_search_reports_the_hubs_words(self):
        _, live = self._pool()
        base = self.serve_yours(asks=[live], search_code=500)
        out = self.seam("--ask-find", "billing", pass_url=base, expect=1)
        self.assertFalse(out["ok"])
        self.assertEqual(out["error"], "search is off")

    def test_no_hub_means_no_find(self):
        """The file fallback has no search endpoint; the seam refuses rather
        than narrowing the local rows under a find label."""
        self.seam("--ask-find", "billing", expect=2)


# --- ⌘D the desk ----------------------------------------------------------------

class TestDeskOpens(YoursCase):
    def test_deskd_opens_the_hubs_desk(self):
        """⌘D's target is the desk the hub serves (H9), on the same base
        every ask read and write uses -- so the menu and the desk can never
        point at different hubs."""
        base = self.serve_yours(asks=[ask_row("qt-run", state="working")])
        out = self.seam("--ask-desk", pass_url=base)
        self.assertTrue(out["ok"])
        self.assertEqual(out["desk_url"], base + "/desk")

    def test_no_hub_means_no_desk(self):
        self.seam("--ask-desk", expect=2)


if __name__ == "__main__":
    unittest.main()
