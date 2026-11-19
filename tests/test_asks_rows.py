#!/usr/bin/env python3
"""Menu bar ask rows (Q3): sections, badge, open-always, read-in-place, done+undo.

Drives the built widget's exit-before-UI seams (`--dump-model --ask-dump-rows`,
with `--ask-expand` / `--ask-done` / `--ask-undo` walkthroughs) against
`AskFixturePass`, plus the off-screen snapshot seam (`--snapshot <png>
--expand <id-substring>`), which renders through cacheDisplay in a window
pinned off any screen -- no panel ever appears on screen. Nothing here posts a
real notification or touches ~/.quicktasks or any live hub file.

Skips (rather than fails) when swiftc is missing, like test_menubar_model.
"""
import live_guard  # noqa: F401  # FIRST: sandboxes QT_DATA etc. before anything reads the env

import json
import struct
import subprocess
import unittest
from pathlib import Path

from asks_harness import BINARY, AskCase, ask_row, job, status_fixture, thread_payload


class RowsCase(AskCase):
    """The `--ask-dump-rows` seam: the same AskBoard the menu draws."""

    def rows(self, base="", *extra, expect=0):
        return self.seam("--ask-dump-rows", *extra, pass_url=base, expect=expect)

    def row_by_id(self, model, ask_id):
        for section in model["sections"]:
            for row in section["rows"]:
                if row["id"] == ask_id:
                    return row
        raise AssertionError(f"{ask_id} not in {[r['id'] for s in model['sections'] for r in s['rows']]}")


class TestSectionsOrder(RowsCase):
    def test_plan_order_new_needs_working_with_the_right_rows(self):
        rows = [
            ask_row("qt-new", state="answer", unseen=True),
            ask_row("qt-seen", state="answer", unseen=False),
            ask_row("qt-fail", state="failed"),
            ask_row("qt-q", state="question"),
            ask_row("qt-go", state="wants_ok"),
            ask_row("qt-run", state="working"),
            ask_row("qt-heard", state="heard"),
            ask_row("qt-done", state="done"),
            ask_row("qt-yours", state="yours"),
        ]
        base = self.serve(asks=rows)
        model = self.rows(base)
        self.assertEqual([s["key"] for s in model["sections"]],
                         ["new_for_you", "needs_you", "working"])
        ids = {s["key"]: s["ids"] for s in model["sections"]}
        self.assertEqual(ids["new_for_you"], ["qt-new"])
        self.assertEqual(set(ids["needs_you"]), {"qt-seen", "qt-fail", "qt-q", "qt-go"})
        self.assertEqual(set(ids["working"]), {"qt-run", "qt-heard"})
        # done and yours have no slice-1 section (yours is Q11) and are not
        # re-bucketed into a section that would lie about them.
        drawn = ids["new_for_you"] + ids["needs_you"] + ids["working"]
        self.assertNotIn("qt-done", drawn)
        self.assertNotIn("qt-yours", drawn)
        # The footer stub the plan fixes.
        self.assertEqual(model["footer"], "Find any ask \u2318F / Open the desk \u2318D")

    def test_needs_you_ranks_decisions_above_read_answers(self):
        rows = [ask_row("qt-seen", state="answer", unseen=False),
                ask_row("qt-go", state="wants_ok"),
                ask_row("qt-fail", state="failed"),
                ask_row("qt-q", state="question")]
        base = self.serve(asks=rows)
        ids = {s["key"]: s["ids"] for s in self.rows(base)["sections"]}
        self.assertEqual(ids["needs_you"], ["qt-q", "qt-fail", "qt-go", "qt-seen"])

    def test_unknown_states_and_places_still_render(self):
        odd = ask_row("qt-odd", state="rethinking", place="elsewhere")
        base = self.serve(asks=[odd, ask_row("qt-new", state="answer", unseen=True)])
        model = self.rows(base)
        needs = next(s for s in model["sections"] if s["key"] == "needs_you")
        self.assertIn("qt-odd", needs["ids"])
        row = self.row_by_id(model, "qt-odd")
        self.assertTrue(row["gray"])
        self.assertEqual(row["detail"], "rethinking")  # the hub's own word, kept

    def test_working_rows_carry_their_age_and_now_line(self):
        run = ask_row("qt-run", state="working", now_line="reading 14 files")
        heard = ask_row("qt-heard", state="heard")
        base = self.serve(asks=[run, heard])
        model = self.rows(base)
        run_row = self.row_by_id(model, "qt-run")
        self.assertEqual(run_row["now_line"], "reading 14 files")
        self.assertTrue(run_row["age"])  # "Working · 3m", not a bare word
        # now_line belongs to working rows only; a finished ask keeps quiet.
        self.assertIsNone(self.row_by_id(model, "qt-heard")["now_line"])


class TestBadgeFromCounts(RowsCase):
    def test_badge_is_the_hubs_number_verbatim(self):
        rows = [ask_row("qt-new", state="answer", unseen=True),
                ask_row("qt-fail", state="failed")]
        # Locally these rows would count 2; the hub says 9 and 9 is what the
        # badge draws -- two clients counting differently is how a badge lies.
        base = self.serve(asks=rows, counts={"badge": 9, "needs": 8, "working": 7,
                                             "done": 6, "yours": 5, "unseen": 4})
        model = self.rows(base)
        self.assertEqual(model["badge"], 9)
        self.assertEqual(model["headline"], "9 asks need you")

    def test_files_path_badge_is_computed_from_the_ledger(self):
        self.write_task("261117-000001-a", status="done", result="r")      # answer, seen
        self.write_task("261117-000002-b", status="failed", result="boom")  # needs
        model = self.rows("")
        self.assertEqual(model["source"], "files")
        self.assertEqual(model["badge"], 1)
        self.assertEqual(model["headline"], "1 ask needs you")

    def test_all_quiet_when_nothing_needs_anyone(self):
        base = self.serve(asks=[ask_row("qt-run", state="working")],
                          counts={"badge": 0, "needs": 0, "working": 1,
                                  "done": 0, "yours": 0, "unseen": 0})
        self.assertEqual(self.rows(base)["headline"], "1 running")


class TestOpenAlwaysEnabled(RowsCase):
    def test_every_state_opens_its_own_url(self):
        states = ["answer", "wants_ok", "working", "question", "blocked",
                  "failed", "heard"]
        rows = [ask_row(f"qt-{s}", state=s) for s in states]
        odd = ask_row("qt-odd", state="rethinking", place="needs")
        base = self.serve(asks=rows + [odd])
        model = self.rows(base)
        for section in model["sections"]:
            for row in section["rows"]:
                self.assertTrue(row["open_enabled"], row["id"])
                self.assertTrue(row["open_url"].endswith(f"/ask/{row['id']}"), row["id"])

    def test_rows_without_moves_still_open(self):
        # A seen answer has no gating move to offer but reading is always allowed.
        row = ask_row("qt-seen", state="answer", unseen=False)
        base = self.serve(asks=[row])
        out = self.row_by_id(self.rows(base), "qt-seen")
        self.assertTrue(out["open_enabled"])
        self.assertTrue(out["open_url"])


class TestSeenOnExpand(RowsCase):
    def test_unseen_answer_reads_in_place_and_posts_seen(self):
        row = ask_row("qt-new", state="answer", unseen=True)
        base = self.serve(asks=[row], threads={"qt-new": thread_payload(row)})
        out = self.rows(base, "--ask-expand", "qt-new")
        exp = out["expanded"]
        self.assertTrue(exp["from_thread"])
        self.assertIn("Renewal is Jan 14", exp["answer_text"])
        self.assertTrue(exp["seen_posted"])
        self.assertTrue(exp["seen_ok"])
        seen = [p for p in self.server.posts if p["move"] == "seen"]
        self.assertEqual(len(seen), 1)
        self.assertEqual(seen[0]["id"], "qt-new")
        self.assertEqual(seen[0]["body"], {})
        self.assertEqual(len(self.server.gets_to("/asks/qt-new.json")), 1)

    def test_a_seen_row_reads_but_does_not_post_seen(self):
        row = ask_row("qt-seen", state="answer", unseen=False)
        base = self.serve(asks=[row], threads={"qt-seen": thread_payload(row)})
        out = self.rows(base, "--ask-expand", "qt-seen")
        self.assertTrue(out["expanded"]["from_thread"])
        self.assertFalse(out["expanded"]["seen_posted"])
        self.assertEqual([p for p in self.server.posts if p["move"] == "seen"], [])

    def test_files_path_shows_the_excerpt_and_posts_nothing(self):
        self.write_task("261117-000001-a", status="done", result="**Bold** answer")
        out = self.rows("", "--ask-expand", "000001-a")
        exp = out["expanded"]
        self.assertEqual(exp["answer_text"], "Bold answer")
        self.assertFalse(exp["post_seen"])

    def test_no_such_row_is_a_clean_refusal(self):
        base = self.serve(asks=[ask_row()])
        self.rows(base, "--ask-expand", "no-such", expect=2)


class TestDoneUndo(RowsCase):
    def test_done_posts_and_leaves_the_undo_line(self):
        row = ask_row("qt-new", state="answer")
        base = self.serve(asks=[row])
        out = self.rows(base, "--ask-done", "qt-new")
        done = out["done"]
        self.assertTrue(done["ok"])
        self.assertEqual(done["line"], "Done \u00B7 Z to undo")
        self.assertEqual(done["undo_token"], "tok-1")
        posts = [p for p in self.server.posts if p["move"] == "done"]
        self.assertEqual(len(posts), 1)
        self.assertEqual(posts[0]["id"], "qt-new")
        self.assertEqual(posts[0]["body"], {})

    def test_z_spends_the_token_on_the_real_undo_route(self):
        row = ask_row("qt-new", state="answer")
        base = self.serve(asks=[row])
        out = self.rows(base, "--ask-done", "qt-new", "--ask-undo")
        self.assertTrue(out["done"]["undo"]["ok"])
        self.assertEqual(out["done"]["undo"]["line"], "Undone")
        undo = [p for p in self.server.posts if p["move"] == "undo"]
        self.assertEqual(len(undo), 1)
        self.assertEqual(undo[0]["id"], "qt-new")
        self.assertEqual(undo[0]["body"], {"token": "tok-1"})

    def test_a_refusal_draws_the_hubs_words_and_no_undo(self):
        reply = {"ok": False, "message": "That ask is already done.", "state": "done",
                 "moves": ["reopen", "follow_up", "retry"]}
        row = ask_row("qt-q", state="question")
        base = self.serve(asks=[row], post_replies={"done": (409, reply)})
        done = self.rows(base, "--ask-done", "qt-q")["done"]
        self.assertFalse(done["ok"])
        self.assertEqual(done["kind"], "not_allowed")
        self.assertEqual(done["line"], "That ask is already done.")
        self.assertIsNone(done["undo_token"])

    def test_rows_without_done_in_their_moves_do_not_offer_it(self):
        # The file fallback carries no moves (the hub is the thing that is
        # down), so E is inert there -- the server is the source of truth.
        self.write_task("261117-000001-a", status="done", result="r")
        model = self.rows("")
        self.assertFalse(self.row_by_id(model, "qt-261117-000001-a")["can_done"])


class TestLegacyFallback(RowsCase):
    def test_a_hub_without_the_ask_api_keeps_its_legacy_rows(self):
        status = status_fixture(jobs=[job("alpha", status="running")])
        base = self.serve(list_code=404, status_payload=status)
        model = self.rows(base)
        self.assertEqual(model["source"], "status")
        self.assertFalse(model["speaks_asks"])
        self.assertEqual(model["sections"], [])
        self.assertEqual(model["legacy_source"], "pass")
        self.assertIn("alpha", model["legacy_ids"])
        self.assertIsNone(model["footer"])  # the stub is the ask menu's only

    def test_ask_menu_speaks_and_carries_the_legacy_side_as_null(self):
        base = self.serve(asks=[ask_row("hub-1", state="working")])
        model = self.rows(base)
        self.assertTrue(model["speaks_asks"])
        self.assertIsNone(model["legacy_source"])


class TestExpandedSnapshot(RowsCase):
    def png_size(self, path):
        data = path.read_bytes()
        self.assertGreaterEqual(len(data), 24)
        self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
        return struct.unpack(">II", data[16:24])

    def png_scale(self, width):
        """Backing-store scale: the render is 480 logical points wide (the
        2026-11-19 readability pass widened the panel from 352), drawn at
        1x or 2x depending on the screen cacheDisplay borrowed."""
        self.assertIn(width, (480, 960))
        return width // 480

    def test_expand_renders_the_answer_off_screen(self):
        row = ask_row("qt-new", state="answer", unseen=True)
        base = self.serve(asks=[row], threads={"qt-new": thread_payload(row)})
        out = self.tmp / "expanded.png"
        proc = subprocess.run(
            [str(BINARY), "--snapshot", str(out), "--expand", "qt-new"],
            capture_output=True, text=True, timeout=60, env=self.env(base))
        self.assertEqual(proc.returncode, 0, proc.stderr + proc.stdout)
        self.assertTrue(out.is_file())
        width, height = self.png_size(out)
        scale = self.png_scale(width)
        self.assertGreater(height, 400 * scale)  # quickfire + sections + expanded peek
        self.assertGreater(out.stat().st_size, 4000)
        # The board really rendered from the fixture, and the row really
        # expanded: the thread was fetched and `seen` went back.
        self.assertGreaterEqual(len(self.server.gets_to("/asks.json")), 1)
        self.assertEqual(len(self.server.gets_to("/asks/qt-new.json")), 1)
        self.assertEqual(len([p for p in self.server.posts if p["move"] == "seen"]), 1)

    def test_a_plain_snapshot_still_renders_without_expanding(self):
        row = ask_row("qt-new", state="answer", unseen=True)
        base = self.serve(asks=[row], threads={"qt-new": thread_payload(row)})
        out = self.tmp / "plain.png"
        proc = subprocess.run(
            [str(BINARY), "--snapshot", str(out)],
            capture_output=True, text=True, timeout=60, env=self.env(base))
        self.assertEqual(proc.returncode, 0, proc.stderr + proc.stdout)
        width, height = self.png_size(out)
        scale = self.png_scale(width)
        self.assertGreater(height, 250 * scale)
        # No --expand: nothing fetched a thread, nothing posted seen.
        self.assertEqual(self.server.gets_to("/asks/qt-new.json"), [])
        self.assertEqual([p for p in self.server.posts if p["move"] == "seen"], [])


if __name__ == "__main__":
    unittest.main()
