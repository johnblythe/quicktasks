#!/usr/bin/env python3
"""Menu bar ask moves in the row (Q9): buttons from the server's moves list,
keys that post them, the prefilled try-with-changes editor, keys inert while
a field has focus, the undo line from the response's token, and the hub's own
message on a 501/409.

Drives the built widget's exit-before-UI seams -- `--ask-dump-rows` for the
buttons a row draws, `--ask-press` for what one key does and the POST it
makes -- against `AskFixturePass`, which records every POST. Nothing here
draws a panel, posts a real notification, or touches ~/.quicktasks or any
live hub file: every test points QT_DATA / QT_HUB at a temp dir and
QT_PASS_URL at the fixture.

Skips (rather than fails) when swiftc is missing, like test_menubar_model.
"""
import live_guard  # noqa: F401  # FIRST: sandboxes QT_DATA etc. before anything reads the env

import unittest

from asks_harness import AskCase, ask_row


class MovesCase(AskCase):
    """The two Q9 seams: the rows a board draws, and one key pressed on one
    of them."""

    def rows(self, base="", *extra, expect=0):
        return self.seam("--ask-dump-rows", *extra, pass_url=base, expect=expect)

    def press(self, needle, key, base="", *extra, expect=0):
        return self.seam("--ask-press", needle, key, *extra, pass_url=base, expect=expect)

    def row_by_id(self, model, ask_id):
        for section in model["sections"]:
            for row in section["rows"]:
                if row["id"] == ask_id:
                    return row
        raise AssertionError(f"{ask_id} not in {[r['id'] for s in model['sections'] for r in s['rows']]}")

    def buttons(self, model, ask_id):
        return self.row_by_id(model, ask_id)["buttons"]

    def posted(self, move):
        return [p for p in self.server.posts if p["move"] == move]


class TestButtonsFromMoves(MovesCase):
    def test_answer_row_offers_the_plans_five_in_order(self):
        base = self.serve(asks=[ask_row("qt-new", state="answer", unseen=True)])
        buttons = self.buttons(self.rows(base), "qt-new")
        self.assertEqual([b["title"] for b in buttons],
                         ["Follow up\u2026", "Redo with changes\u2026", "Copy", "Open", "Done"])
        self.assertEqual([b["key"] for b in buttons], ["r", "R", "c", "return", "e"])
        # The two ask-first writes are text moves under their own body keys;
        # copy and open are client-only; done posts bare.
        by_title = {b["title"]: b for b in buttons}
        self.assertEqual(by_title["Follow up\u2026"]["move"], "follow_up")
        self.assertTrue(by_title["Follow up\u2026"]["text_input"])
        self.assertEqual(by_title["Follow up\u2026"]["body_key"], "text")
        self.assertEqual(by_title["Redo with changes\u2026"]["body_key"], "prompt")
        self.assertEqual(by_title["Copy"]["client"], "copy")
        self.assertEqual(by_title["Open"]["client"], "open")
        self.assertEqual(by_title["Done"]["move"], "done")
        self.assertFalse(by_title["Done"]["text_input"])

    def test_failed_row_offers_its_four_and_the_last_attempt_line(self):
        # ask_row's facts: 184s elapsed, $0.41, sonnet.
        base = self.serve(asks=[ask_row("qt-fail", state="failed")])
        row = self.row_by_id(self.rows(base), "qt-fail")
        self.assertEqual([b["title"] for b in row["buttons"]],
                         ["Try with changes\u2026", "Try again", "I'll do it", "Drop"])
        self.assertEqual([b["key"] for b in row["buttons"]], ["return", None, None, None])
        self.assertEqual(row["last_attempt"], "Last attempt: 3m \u00B7 $0.41 \u00B7 Sonnet")

    def test_blocked_row_offers_the_plans_four(self):
        base = self.serve(asks=[ask_row("qt-block", state="blocked")])
        buttons = self.buttons(self.rows(base), "qt-block")
        self.assertEqual([b["title"] for b in buttons],
                         ["Allow once", "Always allow", "Skip", "Stop"])
        self.assertEqual([b["key"] for b in buttons], ["a", "A", None, "x"])

    def test_question_row_is_the_inline_answer_field(self):
        row = ask_row("qt-q", state="question", question="Which alias should it write to?")
        base = self.serve(asks=[row])
        out = self.row_by_id(self.rows(base), "qt-q")
        self.assertTrue(out["answer_field"])
        self.assertEqual(len(out["buttons"]), 1)
        field = out["buttons"][0]
        self.assertTrue(field["inline"])
        self.assertEqual(field["move"], "follow_up")
        self.assertTrue(field["text_input"])
        self.assertEqual(field["body_key"], "text")

    def test_working_row_offers_stop(self):
        base = self.serve(asks=[ask_row("qt-run", state="working")])
        buttons = self.buttons(self.rows(base), "qt-run")
        self.assertEqual([b["title"] for b in buttons], ["Stop"])
        self.assertEqual(buttons[0]["move"], "stop")

    def test_the_hubs_moves_list_is_the_source_of_truth(self):
        rows = [
            ask_row("qt-thin", state="answer", moves=["done"]),
            ask_row("qt-one", state="blocked", moves=["allow_once"]),
            ask_row("qt-bare", state="working", moves=[]),
        ]
        base = self.serve(asks=rows)
        model = self.rows(base)
        # An answer offering only done keeps Open (client-only, ungated) and
        # Done; a blocked row offering only allow_once offers only that; a
        # working row the hub left moveless offers nothing.
        self.assertEqual([b["title"] for b in self.buttons(model, "qt-thin")],
                         ["Open", "Done"])
        self.assertEqual([b["title"] for b in self.buttons(model, "qt-one")],
                         ["Allow once"])
        self.assertEqual(self.buttons(model, "qt-bare"), [])

    def test_states_and_feeds_without_curated_moves_offer_nothing(self):
        rows = [ask_row("qt-go", state="wants_ok"), ask_row("qt-heard", state="heard")]
        base = self.serve(asks=rows)
        model = self.rows(base)
        self.assertEqual(self.buttons(model, "qt-go"), [])
        self.assertEqual(self.buttons(model, "qt-heard"), [])
        # The file fallback carries no moves at all (the hub is the thing
        # that is down), so no button it cannot honour is ever drawn.
        self.write_task("261117-000001-a", status="failed", result="boom")
        file_model = self.rows("")
        self.assertEqual(file_model["source"], "files")
        self.assertEqual(self.buttons(file_model, "qt-261117-000001-a"), [])


class TestPrefillOriginalWords(MovesCase):
    WORDS = "who owns the billing contact for our GitHub renewal"

    def test_try_with_changes_opens_on_the_original_words(self):
        base = self.serve(asks=[ask_row("qt-fail", state="failed")])
        out = self.press("qt-fail", "return", base)
        self.assertEqual(out["pressed"]["title"], "Try with changes\u2026")
        self.assertEqual(out["prefill"], self.WORDS)
        self.assertTrue(out["posted"])
        # No typed override: the words the field opened with are the words
        # that reach the server.
        self.assertEqual(self.posted("retry_with_changes")[0]["body"], {"prompt": self.WORDS})

    def test_redo_with_changes_on_an_answer_is_prefilled_too(self):
        base = self.serve(asks=[ask_row("qt-new", state="answer")])
        out = self.press("qt-new", "R", base)
        self.assertEqual(out["move"], "retry_with_changes")
        self.assertEqual(out["prefill"], self.WORDS)
        self.assertEqual(self.posted("retry_with_changes")[0]["body"], {"prompt": self.WORDS})

    def test_a_typed_override_replaces_the_prefill(self):
        base = self.serve(asks=[ask_row("qt-fail", state="failed")])
        out = self.press("qt-fail", "return", base, "--ask-text", "ask finance instead")
        self.assertEqual(out["prefill"], self.WORDS)
        self.assertEqual(self.posted("retry_with_changes")[0]["body"],
                         {"prompt": "ask finance instead"})

    def test_follow_up_has_no_prefill_and_posts_nothing_without_words(self):
        base = self.serve(asks=[ask_row("qt-new", state="answer")])
        out = self.press("qt-new", "r", base)
        self.assertEqual(out["move"], "follow_up")
        self.assertEqual(out["prefill"], "")
        self.assertFalse(out["posted"])
        self.assertTrue(out["needs_text"])
        self.assertEqual(self.server.posts, [])


class TestKeysPostMoves(MovesCase):
    def test_blocked_keys_post_their_moves(self):
        base = self.serve(asks=[ask_row("qt-block", state="blocked")])
        self.press("qt-block", "a", base)
        self.press("qt-block", "A", base)
        self.press("qt-block", "x", base)
        self.assertEqual([p["move"] for p in self.server.posts],
                         ["allow_once", "allow_always", "stop"])
        for post in self.server.posts:
            self.assertEqual(post["id"], "qt-block")
            self.assertEqual(post["body"], {})

    def test_answer_keys_post_done_and_a_follow_up(self):
        base = self.serve(asks=[ask_row("qt-new", state="answer")])
        self.press("qt-new", "e", base)
        self.assertEqual(self.posted("done")[0]["body"], {})
        self.press("qt-new", "r", base, "--ask-text", "and when is it due?")
        self.assertEqual(self.posted("follow_up")[0]["body"], {"text": "and when is it due?"})

    def test_return_on_an_answer_opens_the_thread_without_posting(self):
        base = self.serve(asks=[ask_row("qt-new", state="answer")])
        out = self.press("qt-new", "return", base)
        self.assertEqual(out["client"], "open")
        self.assertFalse(out["posted"])
        self.assertEqual(self.server.posts, [])

    def test_a_key_the_row_does_not_carry_resolves_nothing(self):
        base = self.serve(asks=[ask_row("qt-run", state="working")])
        out = self.press("qt-run", "r", base)
        self.assertIsNone(out["pressed"])
        self.assertFalse(out["posted"])
        self.assertEqual(self.server.posts, [])


class TestKeysInertInField(MovesCase):
    def test_every_key_is_inert_while_a_field_has_focus(self):
        rows = [ask_row("qt-new", state="answer"), ask_row("qt-block", state="blocked")]
        base = self.serve(asks=rows)
        # The same keys that post moves when nothing is focused resolve
        # nothing while a row's field owns the keystroke, so typing an
        # answer can never fire E under the words.
        for needle, key in [("qt-new", "e"), ("qt-new", "r"), ("qt-block", "a"),
                            ("qt-block", "A"), ("qt-block", "x")]:
            out = self.press(needle, key, base, "--ask-in-field")
            self.assertIsNone(out["pressed"], (needle, key))
            self.assertFalse(out["posted"], (needle, key))
        self.assertEqual(self.server.posts, [])

    def test_return_is_inert_in_a_field_too(self):
        base = self.serve(asks=[ask_row("qt-fail", state="failed")])
        out = self.press("qt-fail", "return", base, "--ask-in-field")
        self.assertIsNone(out["pressed"])
        self.assertFalse(out["posted"])
        self.assertEqual(self.server.posts, [])


class TestUndoFromToken(MovesCase):
    def test_every_write_leaves_the_undo_line_with_its_token(self):
        base = self.serve(asks=[ask_row("qt-block", state="blocked")])
        out = self.press("qt-block", "x", base)
        self.assertTrue(out["ok"])
        self.assertEqual(out["line"], "Stopped \u00B7 Z to undo")
        self.assertEqual(out["undo_token"], "tok-1")

    def test_undo_spends_the_token_on_the_real_undo_route(self):
        base = self.serve(asks=[ask_row("qt-block", state="blocked")])
        out = self.press("qt-block", "x", base, "--ask-undo")
        self.assertTrue(out["undo"]["ok"])
        self.assertEqual(out["undo"]["line"], "Undone")
        undo = self.posted("undo")
        self.assertEqual(len(undo), 1)
        self.assertEqual(undo[0]["id"], "qt-block")
        self.assertEqual(undo[0]["body"], {"token": "tok-1"})

    def test_no_token_no_undo_offer(self):
        reply = {"ok": True, "ask": ask_row("qt-block", state="working"),
                 "undo": None, "message": "Stopped."}
        base = self.serve(asks=[ask_row("qt-block", state="blocked")],
                          post_replies={"stop": (200, reply)})
        out = self.press("qt-block", "x", base)
        self.assertTrue(out["ok"])
        self.assertEqual(out["line"], "Stopped")
        self.assertIsNone(out["undo_token"])


class Test501Message(MovesCase):
    def test_501_shows_the_hubs_message_not_a_dead_button(self):
        # An H2-era hub: every move registered, the run engine not built.
        reply = {"ok": False, "message": "allow_once is not built yet",
                 "state": "blocked",
                 "moves": ["allow_once", "allow_always", "skip", "follow_up", "stop"]}
        base = self.serve(asks=[ask_row("qt-block", state="blocked")],
                          post_replies={"allow_once": (501, reply)})
        out = self.press("qt-block", "a", base)
        # The button still fired -- the POST went out -- and the line is the
        # server's own sentence.
        self.assertTrue(out["posted"])
        self.assertFalse(out["ok"])
        self.assertEqual(out["kind"], "not_built")
        self.assertEqual(out["line"], "allow_once is not built yet")
        self.assertEqual(len(self.posted("allow_once")), 1)

    def test_409_shows_the_hubs_message(self):
        reply = {"ok": False, "message": "That ask is already done.",
                 "state": "done", "moves": ["reopen", "follow_up", "retry"]}
        base = self.serve(asks=[ask_row("qt-new", state="answer")],
                          post_replies={"done": (409, reply)})
        out = self.press("qt-new", "e", base)
        self.assertEqual(out["kind"], "not_allowed")
        self.assertEqual(out["line"], "That ask is already done.")
        self.assertIsNone(out["undo_token"])


if __name__ == "__main__":
    unittest.main()
