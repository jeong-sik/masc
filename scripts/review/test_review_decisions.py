#!/usr/bin/env python3
"""Exact-head decision ownership and chronological replacement behavior."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("review_decisions", HERE / "review-decisions.py")
M = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = M
SPEC.loader.exec_module(M)
HEAD = "a" * 40
OLD = "b" * 40
T1 = "2026-10-26T10:00:00Z"
T2 = "2026-10-26T10:01:00Z"
T3 = "2026-10-26T10:02:00Z"


def item(state, *, actor="reviewer-a", at=T1, updated=None, kind="comment",
         rid=1, head=HEAD, by="claimed-keeper", assoc="COLLABORATOR",
         review_state="COMMENTED", body=None):
    record = {
        "id": rid, "body": body or f"verdict: {state} head: {head} by: {by}",
        "author_association": assoc,
        "user": {"login": actor} if actor is not None else {},
        "html_url": f"https://github.example/review/{rid}",
    }
    if kind == "review":
        record.update(submitted_at=at, state=review_state)
    else:
        record.update(created_at=at, updated_at=updated or at)
    return {"kind": kind, "record": record}


def reduce(*rows, actor=None, exclude=()):
    return M.reduce_decisions(rows, head=HEAD, actor=actor,
                              exclude_reviews=frozenset(exclude))


class ReviewDecisionCases(unittest.TestCase):
    def test_unrelated_pass_cannot_erase_hold(self):
        result = reduce(item("HOLD"), item("PASS", actor="reviewer-b", at=T2, rid=2))
        self.assertEqual(result.selected.state, M.State.HOLD)
        self.assertEqual([x.actor for x in result.blockers], ["reviewer-a"])

    def test_pr_author_pass_cannot_erase_another_actors_fail(self):
        result = reduce(item("FAIL"), item("PASS", actor="pr-author", at=T2, rid=2))
        self.assertEqual(result.selected.state, M.State.FAIL)
        self.assertEqual(result.selected.actor, "reviewer-a")

    def test_same_actor_can_replace_own_fail_across_record_kinds(self):
        result = reduce(item("FAIL"), item("PASS", at=T2, kind="review", rid=2,
                                            review_state="APPROVED"))
        self.assertEqual(result.verdict(), "PASS - claimed-keeper")
        self.assertFalse(result.blockers)

    def test_multiple_own_crs_are_superseded_by_their_actors_new_review(self):
        result = reduce(item("FAIL", kind="review", review_state="CHANGES_REQUESTED"),
                        item("FAIL", at=T2, kind="review", rid=2,
                             review_state="CHANGES_REQUESTED"),
                        item("PASS", at=T3, kind="review", rid=3,
                             review_state="APPROVED"))
        self.assertEqual(result.selected.state, M.State.PASS)
        self.assertEqual(len(result.decisions), 1)

    def test_pass_formatted_cr_cannot_clear_the_actors_older_fail(self):
        result = reduce(item("FAIL", kind="review", review_state="CHANGES_REQUESTED"),
                        item("PASS", at=T2, kind="review", rid=2,
                             review_state="CHANGES_REQUESTED"))
        self.assertEqual(result.selected.state, M.State.INVALID)
        self.assertEqual(result.selected.record_id, 2)
        self.assertTrue(result.blockers)

    def test_standalone_pass_formatted_cr_is_a_blocking_contradiction(self):
        result = reduce(item("PASS", kind="review", review_state="CHANGES_REQUESTED"))
        self.assertEqual(result.selected.state, M.State.INVALID)
        self.assertTrue(result.blockers)

    def test_correct_approved_replacement_clears_own_cr_and_prior_contradiction(self):
        result = reduce(item("FAIL", kind="review", review_state="CHANGES_REQUESTED"),
                        item("PASS", at=T2, kind="review", rid=2,
                             review_state="CHANGES_REQUESTED"),
                        item("PASS", at=T3, kind="review", rid=3,
                             review_state="APPROVED"))
        self.assertEqual(result.selected.state, M.State.PASS)
        self.assertFalse(result.blockers)

    def test_own_pass_does_not_withdraw_another_actor(self):
        result = reduce(item("FAIL"), item("HOLD", actor="reviewer-b", rid=2),
                        item("PASS", at=T2, rid=3))
        self.assertEqual(result.selected.actor, "reviewer-b")
        self.assertEqual(result.selected.state, M.State.HOLD)

    def test_claimed_keeper_name_does_not_own_another_accounts_record(self):
        result = reduce(item("FAIL", by="same-claimed-name"),
                        item("PASS", actor="reviewer-b", by="same-claimed-name", at=T2, rid=2))
        self.assertEqual(result.selected.state, M.State.FAIL)

    def test_actor_can_change_claimed_name_without_losing_ownership(self):
        result = reduce(item("FAIL", by="first-keeper"),
                        item("PASS", by="second-keeper", at=T2, rid=2))
        self.assertEqual(result.verdict(), "PASS - second-keeper")

    def test_all_independent_refusals_are_retained_in_diagnostics(self):
        result = reduce(item("FAIL"), item("HOLD", actor="reviewer-b", at=T2, rid=2))
        self.assertEqual({r["actor"] for r in result.to_json()["blockers"]},
                         {"reviewer-a", "reviewer-b"})
        self.assertEqual(result.to_json()["blockers"][0]["id"], 2)
        self.assertEqual(result.to_json()["blockers"][0]["url"],
                         "https://github.example/review/2")

    def test_missing_actor_pass_never_authorizes_or_withdraws(self):
        result = reduce(item("FAIL"), item("PASS", actor=None, at=T2, rid=2))
        self.assertIn(M.State.FAIL, [d.state for d in result.blockers])
        self.assertIn(M.State.UNTRUSTED, [d.state for d in result.blockers])

    def test_missing_actor_records_cannot_withdraw_each_other(self):
        result = reduce(item("FAIL", actor=None), item("PASS", actor=None, at=T2, rid=2))
        self.assertEqual(len(result.blockers), 2)

    def test_untrusted_pass_cannot_clear_own_fail(self):
        result = reduce(item("FAIL"), item("PASS", at=T2, rid=2, assoc="CONTRIBUTOR"))
        self.assertTrue(result.blockers)
        self.assertEqual(result.selected.state, M.State.UNTRUSTED)

    def test_editing_an_old_pass_does_not_move_it_past_a_refusal(self):
        result = reduce(item("PASS", at=T1, updated=T3), item("FAIL", at=T2, rid=2))
        self.assertEqual(result.selected.state, M.State.FAIL)

    def test_negative_edit_revokes_positive_authority(self):
        result = reduce(item("FAIL", at=T1, updated=T3), item("PASS", at=T2, rid=2))
        self.assertEqual(result.selected.state, M.State.FAIL)

    def test_equal_timestamp_conflict_refuses_regardless_of_input_order(self):
        for rows in ((item("PASS"), item("FAIL", rid=2)),
                     (item("FAIL", rid=2), item("PASS"))):
            with self.subTest(rows=rows):
                self.assertEqual(reduce(*rows).selected.state, M.State.FAIL)

    def test_old_head_decisions_do_not_affect_current_head(self):
        result = reduce(item("FAIL", head=OLD), item("PASS", at=T2, rid=2))
        self.assertEqual(result.selected.state, M.State.PASS)

    def test_dismissed_review_is_withdrawn_but_separate_comment_is_not(self):
        result = reduce(item("FAIL", kind="review", review_state="DISMISSED"),
                        item("HOLD", rid=2))
        self.assertEqual(len(result.decisions), 1)
        self.assertEqual(result.selected.kind, M.Kind.COMMENT)

    def test_pending_pass_cannot_clear_published_fail(self):
        result = reduce(item("FAIL", kind="review", review_state="CHANGES_REQUESTED"),
                        item("PASS", kind="review", review_state="PENDING", at=T2, rid=2))
        self.assertEqual(result.selected.state, M.State.FAIL)
        self.assertEqual(result.selected.record_id, 1)

    def test_pending_negative_has_no_published_authority(self):
        result = reduce(item("PASS", kind="review", review_state="APPROVED"),
                        item("FAIL", kind="review", review_state="PENDING", at=T2, rid=2))
        self.assertEqual(result.selected.state, M.State.PASS)
        self.assertFalse(result.blockers)
        self.assertEqual(len(result.decisions), 1)

    def test_unknown_review_state_never_grants_pass(self):
        for state in ("FUTURE_STATE", None, ""):
            with self.subTest(state=state):
                result = reduce(item("PASS", kind="review", review_state=state))
                self.assertEqual(result.selected.state, M.State.UNKNOWN)
                self.assertTrue(result.blockers)

    def test_validated_exclusion_names_only_a_formal_cr(self):
        result = reduce(item("FAIL", kind="review", review_state="CHANGES_REQUESTED"),
                        item("HOLD", actor="reviewer-b", rid=1), exclude=(1,))
        self.assertEqual(result.selected.state, M.State.HOLD)
        self.assertEqual(result.selected.actor, "reviewer-b")

    def test_exclusion_cannot_remove_a_commented_review(self):
        result = reduce(item("FAIL", kind="review"), exclude=(1,))
        self.assertEqual(result.selected.state, M.State.FAIL)

    def test_actor_filter_is_only_an_own_decision_view(self):
        result = reduce(item("FAIL"), item("PASS", actor="reviewer-b", at=T2, rid=2),
                        actor="reviewer-b")
        self.assertEqual(result.selected.state, M.State.PASS)
        self.assertEqual(len(result.decisions), 1)
        self.assertEqual(reduce(item("FAIL"), actor="reviewer-b").verdict(), "")

    def test_actor_filter_retains_unidentified_refusals(self):
        result = reduce(item("FAIL", actor=None), actor="reviewer-b")
        self.assertEqual(result.selected.state, M.State.FAIL)

    def test_malformed_positive_header_is_never_pass(self):
        for body in (f"verdict: PASS head: {HEAD} by:",
                     f"verdict: PASS head: {HEAD} by: keeper extra",
                     f"verdict: PASS head: {HEAD} head: {HEAD} by: keeper"):
            with self.subTest(body=body):
                self.assertEqual(reduce(item("PASS", body=body)).selected.state, M.State.INVALID)

    def test_unknown_named_verdict_conservatively_blocks(self):
        result = reduce(item("SOMETHING"))
        self.assertEqual(result.selected.state, M.State.UNKNOWN)

    def test_release_run_is_preserved(self):
        result = reduce(item("PASS", body=f"verdict: PASS head: {HEAD} run: 123 by: keeper"))
        self.assertEqual(result.verdict(), "PASS 123 keeper")

    def test_free_text_is_not_a_review_protocol_record(self):
        self.assertIsNone(reduce(item("PASS", body="source review complete")).selected)

    def test_structured_records_require_usable_timestamps(self):
        row = item("PASS")
        row["record"].pop("created_at")
        with self.assertRaises(ValueError):
            reduce(row)

    def test_cli_emits_blocker_provenance(self):
        result = subprocess.run([sys.executable, str(HERE / "review-decisions.py"),
                                 "--head", HEAD, "--format", "json"],
                                input=json.dumps(item("HOLD")) + "\n",
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data["blockers"][0]["actor"], "reviewer-a")
        self.assertEqual(data["blockers"][0]["kind"], "comment")

    def test_cli_refuses_corrupt_or_unknown_envelopes(self):
        for text in ("not json\n", '{"kind":"unknown","record":{}}\n'):
            with self.subTest(text=text):
                result = subprocess.run([sys.executable, str(HERE / "review-decisions.py"),
                                         "--head", HEAD], input=text,
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertIn("review-decisions:", result.stderr)


if __name__ == "__main__":
    unittest.main()
