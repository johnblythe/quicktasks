#!/usr/bin/env python3
"""Menu bar ask feed (Q2): the ask contract's client side.

Drives the built widget's exit-before-UI seams (`--dump-model --ask-dump-model`,
`--ask-dump-thread`, `--ask-post`) against `AskFixturePass`, a loopback server
speaking section 1 of the plan. Nothing here opens a panel, posts a real
notification, or touches ~/.quicktasks or any live hub file.

Skips (rather than fails) when swiftc is missing, like test_menubar_model.
"""
import json
import unittest

from asks_harness import (DEAD_URL, AskCase, ask_row, counts_for, job,
                          status_fixture, thread_payload)


class TestAskDecode(AskCase):
    def test_row_fields_survive_the_round_trip(self):
        base = self.serve(asks=[ask_row()])
        model = self.ask_model(base)
        self.assertEqual(model["source"], "asks")
        row = self.by_id(model, "qt-261117-094512-who-owns-the")
        self.assertEqual(row["state"], "answer")
        self.assertEqual(row["place"], "needs")
        self.assertTrue(row["unseen"])
        self.assertEqual(row["door"], "typed")
        self.assertEqual(row["item_id"], "qt-261117-094512-who-owns-the")
        self.assertEqual(row["created_at"], "2026-11-17T09:45:12-05:00")
        self.assertEqual(row["facts"]["cost_usd"], 0.41)
        self.assertEqual(row["facts"]["tools_used"], ["Slack", "Drive"])
        self.assertEqual(row["moves"], ["follow_up", "retry", "retry_with_changes", "copy", "done"])
        self.assertIn("Procurement", row["answer_excerpt"])
        self.assertFalse(row["gray"])

    def test_unknown_fields_are_ignored(self):
        row = ask_row(future_field={"a": [1, 2]}, another="x")
        row["facts"]["new_fact"] = 7
        base = self.serve(asks=[row])
        model = self.ask_model(base)
        self.assertEqual(model["count"], 1)
        self.assertNotIn("future_field", self.by_id(model, row["id"]))

    def test_unknown_state_is_kept_and_gray(self):
        base = self.serve(asks=[ask_row("hub-1", state="rethinking", place="needs")])
        row = self.by_id(self.ask_model(base), "hub-1")
        self.assertEqual(row["state"], "rethinking")
        self.assertTrue(row["gray"])

    def test_known_states_are_not_gray(self):
        states = ["heard", "wants_ok", "working", "question", "blocked",
                  "failed", "answer", "done", "yours"]
        base = self.serve(asks=[ask_row(f"hub-{s}", state=s) for s in states])
        model = self.ask_model(base)
        self.assertEqual(model["count"], len(states))
        for s in states:
            self.assertFalse(self.by_id(model, f"hub-{s}")["gray"], s)

    def test_wrong_types_and_idless_rows_do_not_cost_the_list(self):
        good = ask_row("hub-good", state="working")
        bad_types = ask_row("hub-odd", state="working")
        bad_types["facts"] = "not a dict"
        bad_types["moves"] = "stop"
        bad_types["unseen"] = "yes"
        base = self.serve(asks=[good, bad_types, {"title": "no id"}, "junk", 7])
        model = self.ask_model(base)
        self.assertEqual(sorted(model["ids"]), ["hub-good", "hub-odd"])
        odd = self.by_id(model, "hub-odd")
        self.assertEqual(odd["moves"], [])
        self.assertFalse(odd["unseen"])

    def test_counts_come_from_the_hub(self):
        rows = [ask_row("a", state="answer"), ask_row("b", state="failed"),
                ask_row("c", state="working")]
        base = self.serve(asks=rows, counts={"badge": 9, "needs": 8, "working": 7,
                                             "done": 6, "yours": 5, "unseen": 4})
        counts = self.ask_model(base)["counts"]
        self.assertEqual(counts, {"badge": 9, "needs": 8, "working": 7,
                                  "done": 6, "yours": 5, "unseen": 4})

    def test_thread_decodes_answer_timeline_and_runs(self):
        row = ask_row()
        base = self.serve(asks=[row], threads={row["id"]: thread_payload(row, surprise=1)})
        out = self.seam("--ask-dump-thread", row["id"], pass_url=base)
        self.assertTrue(out["ok"])
        self.assertEqual(out["ask"]["id"], row["id"])
        self.assertIn("Renewal is Jan 14", out["answer_text"])
        self.assertFalse(out["answer_truncated"])
        self.assertEqual([t["text"] for t in out["timeline"]], ["heard", "started", "finished"])
        run = out["runs"][0]
        self.assertEqual(run["kind"], "first")
        self.assertEqual(run["files"][0]["name"], "summary.md")
        self.assertEqual(run["cost_usd"], 0.41)

    def test_unknown_thread_is_a_404(self):
        base = self.serve(asks=[ask_row()])
        out = self.seam("--ask-dump-thread", "nope", pass_url=base, expect=1)
        self.assertFalse(out["ok"])
        self.assertTrue(out["not_found"])

    def test_thread_is_fetched_once_per_updated_at(self):
        row = ask_row()
        base = self.serve(asks=[row], threads={row["id"]: thread_payload(row)})
        self.seam("--ask-dump-thread", row["id"], "--ask-updated-at", row["updated_at"],
                  "--ask-repeat", "3", pass_url=base)
        self.assertEqual(len(self.server.gets_to(f"/asks/{row['id']}.json")), 1)

    def test_a_row_with_no_updated_at_still_caches_on_the_threads_own(self):
        row = ask_row()
        base = self.serve(asks=[row], threads={row["id"]: thread_payload(row)})
        # No stamp from the caller: nothing to hit on the first call, so each
        # call fetches. Proves the cache never serves a thread without a key.
        self.seam("--ask-dump-thread", row["id"], "--ask-repeat", "2", pass_url=base)
        self.assertEqual(len(self.server.gets_to(f"/asks/{row['id']}.json")), 2)


class TestFeedPrefersAsks(AskCase):
    def test_the_ask_api_wins_and_status_json_is_not_read(self):
        base = self.serve(asks=[ask_row("hub-1", state="wants_ok")],
                          status_payload=status_fixture(jobs=[job("alpha", status="running")]))
        model = self.ask_model(base)
        self.assertEqual(model["source"], "asks")
        self.assertEqual(model["ids"], ["hub-1"])
        self.assertEqual(self.server.gets_to("/status.json"), [])
        self.assertEqual(len(self.server.gets_to("/asks.json")), 1)

    def test_the_hub_list_is_not_merged_with_the_local_ledger(self):
        # The hub already derives qt asks; a second copy from disk would double them.
        self.write_task("261117-000001-local", status="done", result="local")
        base = self.serve(asks=[ask_row("hub-1", state="working")])
        self.assertEqual(self.ask_model(base)["ids"], ["hub-1"])

    def test_rev_and_generated_at_are_carried(self):
        base = self.serve(asks=[ask_row()], rev="rev-42")
        model = self.ask_model(base)
        self.assertEqual(model["rev"], "rev-42")
        self.assertEqual(model["generated_at"], "2026-11-17T09:50:00-05:00")

    def test_a_numeric_rev_is_accepted(self):
        base = self.serve(asks=[ask_row()], rev=7)
        self.assertEqual(self.ask_model(base)["rev"], "7")

    def test_since_rev_goes_on_the_wire_and_unchanged_is_honoured(self):
        base = self.serve(asks=[ask_row()], rev="rev-9")
        model = self.ask_model(base, "--ask-since-rev", "rev-9")
        self.assertTrue(model["unchanged"])
        self.assertEqual(model["source"], "asks")
        self.assertEqual(self.server.gets_to("/asks.json")[0]["query"]["since_rev"], "rev-9")

    def test_a_stale_since_rev_gets_the_whole_list(self):
        base = self.serve(asks=[ask_row()], rev="rev-10")
        model = self.ask_model(base, "--ask-since-rev", "rev-9")
        self.assertFalse(model["unchanged"])
        self.assertEqual(model["count"], 1)

    def test_default_query_asks_for_200(self):
        base = self.serve(asks=[ask_row()])
        self.ask_model(base)
        query = self.server.gets_to("/asks.json")[0]["query"]
        self.assertEqual(query["limit"], "200")
        self.assertNotIn("since_rev", query)


class TestStatusFallback(AskCase):
    def test_a_404_hands_off_to_status_json(self):
        status = status_fixture(jobs=[job("alpha", status="running")],
                                counts={"running": 1, "verify": 0, "gate": 0,
                                        "blocked": 0, "failed": 0})
        base = self.serve(list_code=404, status_payload=status)
        model = self.ask_model(base)
        self.assertEqual(model["source"], "status")
        self.assertEqual(model["asks"], [])
        self.assertEqual(model["status_model"]["source"], "pass")
        self.assertIn("alpha", model["status_model"]["ids"])
        self.assertEqual(len(self.server.gets_to("/status.json")), 1)

    def test_status_path_is_what_dump_model_has_always_shown(self):
        status = status_fixture(jobs=[job("alpha", status="running"), job("beta", status="done")])
        base = self.serve(list_code=404, status_payload=status)
        ask_side = self.ask_model(base)["status_model"]
        legacy = self.seam(pass_url=base)  # plain --dump-model, no ask flag
        self.assertEqual(ask_side["ids"], [r["id"] for r in legacy["records"]])
        self.assertEqual(legacy["source"], "pass")

    def test_404_with_no_status_json_falls_to_the_files(self):
        self.write_task("261117-000001-local", status="done", result="the answer")
        base = self.serve(list_code=404, status_payload=None)
        model = self.ask_model(base)
        self.assertEqual(model["source"], "files")
        self.assertEqual(model["ids"], ["qt-261117-000001-local"])


class TestFileFallbackAsks(AskCase):
    def test_pass_off_reads_the_ledger_as_asks(self):
        self.write_task("261117-000001-a", status="done", result="**Bold** answer",
                        started="2026-11-17T09:45:14", finished="2026-11-17T09:48:16")
        model = self.ask_model("")
        self.assertEqual(model["source"], "files")
        self.assertIsNone(model["pass_url"])
        row = self.by_id(model, "qt-261117-000001-a")
        self.assertEqual(row["ledger"], "qt")
        self.assertEqual(row["kind"], "agent")
        self.assertEqual(row["ref"], "261117-000001-a")
        self.assertEqual(row["item_id"], "qt-261117-000001-a")
        self.assertEqual(row["answer_excerpt"], "Bold answer")
        self.assertEqual(row["facts"]["elapsed_s"], 182)

    def test_pass_down_falls_back_and_says_why(self):
        self.write_task("261117-000001-a", status="running")
        model = self.ask_model(DEAD_URL)
        self.assertEqual(model["source"], "files")
        self.assertEqual(model["pass_url"], DEAD_URL)
        self.assertTrue(model["pass_error"])
        self.assertEqual(self.by_id(model, "qt-261117-000001-a")["url"],
                         f"{DEAD_URL}/ask/qt-261117-000001-a")

    def test_status_mapping_follows_rule_two(self):
        mapping = {"queued": ("heard", "working"), "running": ("working", "working"),
                   "question": ("question", "needs"), "blocked": ("blocked", "needs"),
                   "failed": ("failed", "needs"), "timeout": ("failed", "needs"),
                   "stopped": ("failed", "needs"), "done": ("answer", "needs"),
                   "dropped": ("done", "done")}
        for status in mapping:
            self.write_task(f"261117-{status}", status=status, result="r")
        model = self.ask_model("")
        for status, (state, place) in mapping.items():
            row = self.by_id(model, f"qt-261117-{status}")
            self.assertEqual((row["state"], row["place"]), (state, place), status)
        self.assertEqual(self.by_id(model, "qt-261117-dropped")["filed"], "dropped")

    def test_nothing_is_unseen_and_no_moves_are_offered(self):
        self.write_task("261117-000001-a", status="done", result="r")
        self.write_task("261117-000002-b", status="failed", result="boom")
        model = self.ask_model("")
        for row in model["asks"]:
            self.assertFalse(row["unseen"])
            self.assertEqual(row["moves"], [])
        self.assertEqual(model["counts"]["unseen"], 0)

    def test_badge_counts_needs_minus_seen_answers(self):
        self.write_task("261117-000001-a", status="done", result="r")      # answer, unseen false
        self.write_task("261117-000002-b", status="failed", result="boom")  # needs
        self.write_task("261117-000003-c", status="blocked", result="p")    # needs
        self.write_task("261117-000004-d", status="running")                # working
        counts = self.ask_model("")["counts"]
        self.assertEqual(counts["needs"], 3)
        self.assertEqual(counts["badge"], 2)
        self.assertEqual(counts["working"], 1)

    def test_bridge_records_are_ignored(self):
        self.write_task("261117-000001-a", status="done", result="r", source="pass")
        self.write_task("261117-000002-b", status="done", result="r")
        self.assertEqual(self.ask_model("")["ids"], ["qt-261117-000002-b"])

    def test_door_follows_origin(self):
        for origin in ("summon", "widget", "qt", "raycast"):
            self.write_task(f"261117-{origin}", status="done", result="r", origin=origin)
        model = self.ask_model("")
        doors = {o: self.by_id(model, f"qt-261117-{o}")["door"]
                 for o in ("summon", "widget", "qt", "raycast")}
        self.assertEqual(doors, {"summon": "typed", "widget": "typed",
                                 "qt": "cli", "raycast": "raycast"})

    def test_failed_reason_and_timestamps_with_offset(self):
        self.write_task("261117-000001-a", status="failed", result="Ran out of time after 20 minutes.",
                        started="2026-11-17T09:45:14", finished="2026-11-17T10:05:14")
        row = self.by_id(self.ask_model(""), "qt-261117-000001-a")
        self.assertEqual(row["reason"], "Ran out of time after 20 minutes.")
        for field in ("created_at", "updated_at", "finished_at"):
            self.assertRegex(row[field], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(Z|[+-]\d\d:\d\d)$", field)

    def test_newest_first_and_limit(self):
        self.write_task("261117-000001-old", status="done", result="r", created="2026-11-17T08:00:00",
                        finished="2026-11-17T08:01:00")
        self.write_task("261117-000002-new", status="done", result="r", created="2026-11-17T09:00:00",
                        finished="2026-11-17T09:01:00")
        model = self.seam("--ask-dump-model", "--limit", "1", pass_url="")
        self.assertEqual(model["ids"], ["qt-261117-000002-new"])

    def test_a_garbage_pass_response_also_falls_back(self):
        self.write_task("261117-000001-a", status="done", result="r")
        base = self.serve(list_raw={"rev": "x"})  # no asks list at all
        model = self.ask_model(base)
        self.assertEqual(model["source"], "files")
        self.assertIn("261117-000001-a", model["ids"][0])


class TestPostMove(AskCase):
    def post(self, ask_id, move, body=None, base=None, expect=0):
        args = ["--ask-post", ask_id, move]
        if body is not None:
            args.append(json.dumps(body))
        return self.seam(*args, pass_url=base, expect=expect)

    def test_post_goes_to_the_move_path_with_a_json_body(self):
        base = self.serve()
        out = self.post("hub-1", "follow_up", {"text": "and the renewal date?"}, base)
        post = self.server.posts[0]
        self.assertEqual(post["path"], "/asks/hub-1/follow_up")
        self.assertEqual(post["body"], {"text": "and the renewal date?"})
        self.assertEqual(post["content_type"], "application/json")
        self.assertTrue(out["ok"])
        self.assertEqual(out["kind"], "ok")

    def test_empty_body_is_an_empty_object(self):
        base = self.serve()
        self.post("hub-1", "done", None, base)
        self.assertEqual(self.server.posts[0]["body"], {})

    def test_success_carries_ask_undo_and_message(self):
        base = self.serve()
        out = self.post("hub-1", "done", None, base)
        self.assertEqual(out["status"], 200)
        self.assertEqual(out["message"], "done done")
        self.assertEqual(out["ask"]["id"], "hub-1")
        self.assertEqual(out["undo"]["token"], "tok-1")
        self.assertEqual(out["undo"]["expires_at"], "2026-11-17T10:00:00-05:00")

    def test_a_move_with_no_undo_reports_null(self):
        base = self.serve(post_replies={"seen": (200, {"ok": True, "ask": ask_row("hub-1"),
                                                         "undo": None, "message": "seen"})})
        out = self.post("hub-1", "seen", None, base)
        self.assertIsNone(out["undo"])

    def test_409_is_an_answer_with_state_and_moves(self):
        reply = {"ok": False, "message": "That ask is already done.", "state": "done",
                 "moves": ["reopen", "follow_up", "retry"]}
        base = self.serve(post_replies={"done": (409, reply)})
        out = self.post("hub-1", "done", None, base, expect=1)
        self.assertFalse(out["ok"])
        self.assertEqual(out["status"], 409)
        self.assertEqual(out["kind"], "not_allowed")
        self.assertEqual(out["message"], "That ask is already done.")
        self.assertEqual(out["state"], "done")
        self.assertEqual(out["moves"], ["reopen", "follow_up", "retry"])

    def test_501_503_and_404_are_named(self):
        base = self.serve(post_replies={
            "run": (501, {"ok": False, "message": "not built yet"}),
            "stop": (503, {"ok": False, "message": "ledger busy"}),
        })
        self.assertEqual(self.post("hub-1", "run", None, base, expect=1)["kind"], "not_built")
        self.assertEqual(self.post("hub-1", "stop", None, base, expect=1)["kind"], "busy")
        base2 = self.serve(post_replies={"drop": (404, "unknown ask")})
        out = self.post("nope", "drop", None, base2, expect=1)
        self.assertEqual(out["kind"], "unknown_ask")
        self.assertEqual(out["message"], "unknown ask")

    def test_no_answer_is_a_failure_not_a_crash(self):
        out = self.post("hub-1", "done", None, DEAD_URL, expect=1)
        self.assertFalse(out["ok"])
        self.assertEqual(out["status"], 0)
        self.assertEqual(out["kind"], "failed")
        self.assertTrue(out["message"])

    def test_bad_ids_and_moves_never_become_requests(self):
        base = self.serve()
        out = self.post("../etc/passwd", "done", None, base, expect=1)
        self.assertEqual(out["status"], 0)
        out = self.post("hub-1", "done/../../x", None, base, expect=1)
        self.assertEqual(out["status"], 0)
        self.assertEqual(self.server.posts, [])

    def test_qt_ask_ids_with_colons_and_dots_work(self):
        base = self.serve()
        self.post("hub:item.v2-1", "mine", None, base)
        self.assertEqual(self.server.posts[0]["id"], "hub:item.v2-1")

    def test_pass_off_refuses_cleanly(self):
        self.seam("--ask-post", "hub-1", "done", pass_url="", expect=2)


if __name__ == "__main__":
    unittest.main()
