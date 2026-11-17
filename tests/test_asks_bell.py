#!/usr/bin/env python3
"""Ask notifications that carry the answer (Q6): the bell payload -> banner
mapping, sound, actions, routed POSTs, and the no-duplicate guarantee.

Drives the built widget's exit-before-UI seam `--ask-notice <payload.json>`
(a Q6 seam: it prints the Notice one bell payload -- v2 or v1 -- becomes,
with every action's routed POST, and can really perform one action's POST
against `AskFixturePass`). Nothing here posts a real notification: the seam
prints what `InboxNotice.toNotice` / `AskNoticeRoute` produce -- the same
pure code the watcher and the notification delegate run -- and
`--ask-action` posts to a loopback fixture only. Never
UNUserNotificationCenter, never ~/.quicktasks, never a live hub file.

Skips (rather than fails) when swiftc is missing, like test_menubar_model.
"""
import live_guard  # noqa: F401  # FIRST: sandboxes QT_DATA etc. before anything reads the env

import json
import subprocess
import unittest

from asks_harness import BINARY, AskCase


# --- contract fixtures (plan 1.8; bell.py is the reference) ------------------

BODY_OF = {
    "answer": "Procurement owns it, through the vendor-renewals alias.",
    "failed": "Ran out of time after 10 minutes.",
    "blocked": "Paused: wants mcp__claude_ai_Slack__slack_search_users.",
    "question": "Which alias should the renewal invoices go to?",
    "receipt": "who owns the billing contact for our GitHub renewal",
    "reminder": "Renew the GitHub plan before Jan 14",
}

MOVES_OF = {
    "answer": ["follow_up", "copy", "open"],
    "failed": ["retry", "open"],
    "blocked": ["allow_once", "allow_always", "skip", "open"],
    "question": ["follow_up", "open"],
    "receipt": ["open"],
    "reminder": ["done", "open"],
}


def bell_payload(kind="answer", ask_id="qt-261117-094512-who-owns-the",
                 sound=None, **over):
    """The v2 payload bell.inbox_payload writes, same shape and defaults."""
    sounding = kind in ("failed", "blocked", "question", "reminder")
    p = {
        "v": 2,
        "kind": kind,
        "ask_id": ask_id,
        "task_id": ask_id[3:] if ask_id.startswith("qt-") else None,
        "title": "Billing contact for the GitHub renewal",
        "body": BODY_OF.get(kind, "body"),
        "sound": sounding if sound is None else sound,
        "url": f"http://127.0.0.1:8811/ask/{ask_id}",
        "denied_tools": ["mcp__claude_ai_Slack__slack_search_users"]
                        if kind == "blocked" else [],
        "moves": list(MOVES_OF.get(kind, ["open"])),
        "ts": "2026-11-17T09:48:20-05:00",
        "source": "hub-bell",
    }
    p.update(over)
    return p


def v1_payload(kind="done", task_id="261117-094512-who-owns-the", **over):
    """A pre-bell producer drop: today's keys, none of the v2 ones."""
    p = {
        "title": "Job finished: Billing contact",
        "body": "Procurement owns it, through the vendor-renewals alias.",
        "kind": kind,
        "task_id": task_id,
        "resume_url": f"quicktask://resume/{task_id}",
        "url": f"http://127.0.0.1:8811/job/qt-{task_id}",
        "denied_tools": [],
        "ts": "2026-11-17T09:48:20-05:00",
        "source": "qt",
    }
    p.update(over)
    return p


class BellCase(AskCase):
    """The `--ask-notice` seam, invoked directly (Q6 made Entry route
    --ask-* without the --dump-model companion)."""

    def notice(self, payload, *extra, pass_url="", expect=0, extra_env=None):
        path = self.tmp / "notice.json"
        path.write_text(json.dumps(payload))
        proc = subprocess.run(
            [str(BINARY), "--ask-notice", str(path), *extra],
            capture_output=True, text=True, timeout=60,
            env=self.env(pass_url, extra_env))
        self.assertEqual(
            proc.returncode, expect,
            f"{extra} exited {proc.returncode}: {proc.stderr}\n{proc.stdout}")
        return json.loads(proc.stdout) if proc.stdout.strip() else None

    def action(self, out, action_id):
        for entry in out["actions"]:
            if entry["id"] == action_id:
                return entry
        raise AssertionError(f"{action_id} not in {[a['id'] for a in out['actions']]}")


class TestCategoryPerKind(BellCase):
    def test_every_bell_kind_gets_its_plan_category_and_actions(self):
        want = {
            "answer": ("ask.answer", [
                ("QT_ASK_FOLLOW_UP", "Follow up\u2026", True),
                ("QT_ASK_COPY", "Copy", False),
                ("QT_ASK_OPEN", "Open", False),
            ]),
            "failed": ("ask.failed", [
                ("QT_ASK_RETRY", "Try again", False),
                ("QT_ASK_RETRY_CHANGES", "Change it\u2026", True),
                ("QT_ASK_OPEN", "Open", False),
            ]),
            "blocked": ("ask.blocked", [
                ("QT_ASK_ALLOW_ONCE", "Allow once", False),
                ("QT_ASK_ALLOW_ALWAYS", "Always allow", False),
                ("QT_ASK_SKIP", "Skip that step", False),
            ]),
            "question": ("ask.question", [
                ("QT_ASK_ANSWER", "Answer\u2026", True),
            ]),
            "receipt": ("ask.receipt", []),
            "reminder": ("ask.reminder", []),
        }
        for kind, (category, actions) in want.items():
            with self.subTest(kind=kind):
                out = self.notice(bell_payload(kind=kind))
                self.assertEqual(out["category"], category)
                self.assertEqual(out["kind"], kind)
                self.assertTrue(out["v2"])
                self.assertEqual([(a["id"], a["title"], a["text_input"])
                                  for a in out["actions"]], actions)

    def test_the_notice_carries_the_ask_and_its_one_address(self):
        out = self.notice(bell_payload(kind="answer",
                                       ask_id="qt-261117-094512-who-owns-the"))
        self.assertEqual(out["ask_id"], "qt-261117-094512-who-owns-the")
        self.assertEqual(out["task_id"], "261117-094512-who-owns-the")
        self.assertEqual(out["open_url"],
                         "http://127.0.0.1:8811/ask/qt-261117-094512-who-owns-the")
        # One id per ask+kind: re-posting replaces the banner, never stacks.
        self.assertEqual(out["notice_id"],
                         "ask-qt-261117-094512-who-owns-the-answer")
        self.assertEqual(out["title"], "Billing contact for the GitHub renewal")
        self.assertIn("Procurement owns it", out["body"])

    def test_an_unknown_v2_kind_is_a_plain_banner(self):
        out = self.notice(bell_payload(kind="rethought", v=2))
        self.assertEqual(out["category"], "plain")
        self.assertEqual(out["actions"], [])
        self.assertFalse(out["sound"])

    def test_the_old_companion_spelling_still_works(self):
        # --dump-model --ask-notice was the only spelling before Entry
        # learned --ask-*; both must keep answering.
        path = self.tmp / "notice.json"
        path.write_text(json.dumps(bell_payload(kind="blocked")))
        out = self.seam("--ask-notice", str(path), pass_url="")
        self.assertEqual(out["category"], "ask.blocked")


class TestSoundOnlyBlocksFailures(BellCase):
    def test_only_blocks_failures_questions_and_reminders_sound(self):
        for kind, sound in [("failed", True), ("blocked", True),
                            ("question", True), ("reminder", True),
                            ("answer", False), ("receipt", False)]:
            with self.subTest(kind=kind):
                out = self.notice(bell_payload(kind=kind))
                self.assertEqual(out["sound"], sound)

    def test_a_payload_claiming_sound_for_an_answer_stays_passive(self):
        # The bell decides sound, the client enforces the ceiling (1.8):
        # sound buys the time-sensitive interruption level, and an answer
        # never interrupts however the payload is worded.
        out = self.notice(bell_payload(kind="answer", sound=True))
        self.assertFalse(out["sound"])

    def test_a_sounding_kind_without_the_flag_stays_quiet(self):
        out = self.notice(bell_payload(kind="failed", sound=False))
        self.assertFalse(out["sound"])


class TestReplyPostsFollowUp(BellCase):
    def test_follow_up_on_an_answer_carries_the_typed_text(self):
        out = self.notice(bell_payload(kind="answer"),
                          "--ask-text", "when is the renewal date?")
        follow = self.action(out, "QT_ASK_FOLLOW_UP")
        self.assertEqual(follow["post"],
                         {"move": "follow_up",
                          "body": {"text": "when is the renewal date?"}})

    def test_answering_a_question_posts_follow_up(self):
        out = self.notice(bell_payload(kind="question"),
                          "--ask-text", "billing@company.com")
        answer = self.action(out, "QT_ASK_ANSWER")
        self.assertEqual(answer["post"],
                         {"move": "follow_up", "body": {"text": "billing@company.com"}})

    def test_change_it_posts_retry_with_changes_try_again_posts_retry(self):
        out = self.notice(bell_payload(kind="failed"),
                          "--ask-text", "check the vendor portal instead")
        changes = self.action(out, "QT_ASK_RETRY_CHANGES")
        self.assertEqual(changes["post"],
                         {"move": "retry_with_changes",
                          "body": {"prompt": "check the vendor portal instead"}})
        again = self.action(out, "QT_ASK_RETRY")
        self.assertEqual(again["post"], {"move": "retry", "body": {}})

    def test_blocked_actions_post_their_moves(self):
        out = self.notice(bell_payload(kind="blocked"))
        for action_id, move in [("QT_ASK_ALLOW_ONCE", "allow_once"),
                                ("QT_ASK_ALLOW_ALWAYS", "allow_always"),
                                ("QT_ASK_SKIP", "skip")]:
            self.assertEqual(self.action(out, action_id)["post"],
                             {"move": move, "body": {}}, action_id)

    def test_copy_and_open_are_client_only(self):
        out = self.notice(bell_payload(kind="answer"))
        self.assertEqual(self.action(out, "QT_ASK_COPY").get("post"), None)
        self.assertTrue(self.action(out, "QT_ASK_COPY")["copy"])
        self.assertEqual(self.action(out, "QT_ASK_OPEN").get("post"), None)
        self.assertTrue(self.action(out, "QT_ASK_OPEN")["open"])

    def test_a_reply_really_posts_through_ask_client(self):
        # --ask-action performs the action's real POST: the typed text must
        # reach /asks/<id>/follow_up through AskClient, not just print.
        base = self.serve(asks=[])
        out = self.notice(bell_payload(kind="answer"),
                          "--ask-action", "QT_ASK_FOLLOW_UP",
                          "--ask-text", "when is the renewal date?",
                          pass_url=base)
        self.assertTrue(out["action_post"]["ok"], out["action_post"])
        self.assertEqual(out["action_post"]["move"], "follow_up")
        posts = [p for p in self.server.posts if p["move"] == "follow_up"]
        self.assertEqual(len(posts), 1, self.server.posts)
        self.assertEqual(posts[0]["id"], "qt-261117-094512-who-owns-the")
        self.assertEqual(posts[0]["body"], {"text": "when is the renewal date?"})

    def test_a_blocked_action_really_posts_its_move(self):
        base = self.serve(asks=[])
        out = self.notice(bell_payload(kind="blocked"),
                          "--ask-action", "QT_ASK_ALLOW_ONCE", pass_url=base)
        self.assertTrue(out["action_post"]["ok"])
        posts = [p for p in self.server.posts if p["move"] == "allow_once"]
        self.assertEqual(posts[0]["id"], "qt-261117-094512-who-owns-the")
        self.assertEqual(posts[0]["body"], {})

    def test_a_client_only_action_refuses_rather_than_posting(self):
        self.notice(bell_payload(kind="answer"),
                    "--ask-action", "QT_ASK_COPY", expect=2)


class TestV1Fallback(BellCase):
    def test_v1_kinds_keep_todays_categories(self):
        for kind, category, actions in [
            ("done", "QT_OUTCOME", ["Open in Pass"]),
            ("failed", "QT_OUTCOME", ["Open in Pass"]),
            ("timeout", "QT_OUTCOME", ["Open in Pass"]),
            ("info", "plain", []),
        ]:
            with self.subTest(kind=kind):
                out = self.notice(v1_payload(kind=kind))
                self.assertFalse(out["v2"])
                self.assertEqual(out["category"], category)
                self.assertEqual([a["title"] for a in out["actions"]], actions)
                # v1 banners never had a sound; they still do not.
                self.assertFalse(out["sound"])

    def test_v1_blocked_keeps_resume_and_the_allow_button(self):
        tools = ["mcp__claude_ai_Slack__slack_search_users"]
        out = self.notice(v1_payload(kind="blocked", denied_tools=tools))
        self.assertEqual(out["category"], "QT_BLOCKED")
        self.assertEqual([a["title"] for a in out["actions"]],
                         ["Resume in Terminal", "Always Allow Tool", "Open in Pass"])
        # No denial detail, no dead Always-allow button.
        bare = self.notice(v1_payload(kind="blocked", denied_tools=[]))
        self.assertEqual(bare["category"], "QT_BLOCKED_NOALLOW")

    def test_a_bell_payload_missing_v_is_still_v2(self):
        # isV2 tolerates a bell that omits `v`: ask_id or a kind v1 never
        # had carries the signal.
        out = self.notice(bell_payload(kind="question", v=None))
        out2 = self.notice(bell_payload(kind="answer", v=None))
        self.assertTrue(out["v2"])
        self.assertEqual(out["category"], "ask.question")
        self.assertTrue(out2["v2"])
        self.assertEqual(out2["category"], "ask.answer")


class TestNoDuplicate(BellCase):
    def test_a_v2_notice_silences_the_poll_that_sees_the_landing(self):
        out = self.notice(bell_payload(kind="blocked"))
        dedupe = out["dedupe"]
        self.assertEqual(dedupe["landed_status"], "blocked")
        # The same landing, observed by the poll after the notice: silent.
        self.assertEqual(dedupe["fired_after_notice"], 0)
        # Without the notice, the poll would have bannered.
        self.assertEqual(dedupe["fired_without_notice"], 1)
        # Both spellings of the id are claimed: the bare tid the legacy
        # tracker keys rows by, and the ask id verbatim.
        self.assertIn("261117-094512-who-owns-the", dedupe["suppressed_ids"])
        self.assertIn("qt-261117-094512-who-owns-the", dedupe["suppressed_ids"])

    def test_an_answer_notice_silences_the_finished_poll(self):
        out = self.notice(bell_payload(kind="answer"))
        dedupe = out["dedupe"]
        self.assertEqual(dedupe["landed_status"], "done")
        self.assertEqual(dedupe["fired_after_notice"], 0)
        self.assertEqual(dedupe["fired_without_notice"], 1)

    def test_a_hub_item_ask_is_suppressed_under_its_own_id(self):
        ask_id = "org-orientation-course-101-201-301"
        out = self.notice(bell_payload(kind="failed", ask_id=ask_id, task_id=None))
        dedupe = out["dedupe"]
        # No qt- prefix and no tid: the ask id verbatim (claimed for both
        # the failed and the timeout spelling of the same landing).
        self.assertEqual(set(dedupe["suppressed_ids"]), {ask_id})
        self.assertEqual(dedupe["fired_after_notice"], 0)
        self.assertEqual(dedupe["fired_without_notice"], 1)

    def test_v1_notices_still_suppress_their_landing(self):
        out = self.notice(v1_payload(kind="blocked"))
        dedupe = out["dedupe"]
        self.assertEqual(dedupe["suppressed_ids"], ["261117-094512-who-owns-the"])
        self.assertEqual(dedupe["fired_after_notice"], 0)
        self.assertEqual(dedupe["fired_without_notice"], 1)


if __name__ == "__main__":
    unittest.main()
