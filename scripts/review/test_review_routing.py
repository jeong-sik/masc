#!/usr/bin/env python3
"""Review routing scenarios across PRs, account ownership, and live requests."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import unittest
import zlib

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("review_routing", HERE / "review-routing.py")
M = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = M
SPEC.loader.exec_module(M)
HEAD = "a" * 40
OLD = "b" * 40
BASE = "c" * 40
T1 = "2026-10-26T10:00:00Z"
T2 = "2026-10-26T11:00:00Z"
T3 = "2026-10-26T12:00:00Z"


def uid(name):
    return zlib.crc32(name.casefold().encode()) + 1


def review(actor="alice", *, state="CHANGES_REQUESTED", head=OLD, rid=1, at=T1):
    return {"id": rid, "user": {"login": actor, "id":uid(actor)}, "state": state,
            "commit_id": head, "submitted_at": at, "body": "source findings"}


def signed_request(actor="alice", *, keeper="one", rid=1, at=T1, head=OLD):
    row = review(actor, rid=rid, at=at, head=head)
    row["body"] = f"verdict: FAIL head: {head} by: {keeper}\nproblem"
    return row


def replacement(actor="alice", *, keeper="one", rid=2, request=1, at=T2):
    row = review(actor, state="APPROVED", head=HEAD, rid=rid, at=at)
    row["author_association"] = "MEMBER"
    row["body"] = (f"verdict: PASS head: {HEAD} by: {keeper}\n"
                   f'review-scope: {{"base_ref":"main","base_sha":"{BASE}","stack":null}}\n'
                   f"approve-guard: head `{HEAD}` · source review · replaces own CHANGES_REQUESTED {request}"
                   f" · reviewed base `{BASE}` · diff sha256 `{'d' * 64}`")
    return row


def pull(number=1, **changes):
    raw = {"number": number, "title": f"Fix {number}", "url": f"https://example/pull/{number}",
           "state": "open", "draft": False, "author": "author", "head": HEAD,
           "base_ref": "main", "base_sha": BASE, "stack": None, "created_at": T1,
           "requested_reviewers": [], "requested_teams": [], "reviews": [],
           "commit_accounts": [], "commit_identities_complete": True,
           "admission": False, "independent_source_review": False, "blockers": []}
    raw.update(changes)
    names = [raw['author'], 'alice', 'bob', *raw['requested_reviewers'], *raw['commit_accounts']]
    names.extend(r['user']['login'] for r in raw['reviews'])
    raw.setdefault('account_ids', {name.casefold():uid(name) for name in names})
    raw.setdefault('author_id', uid(raw['author']))
    raw.setdefault('commit_actor_ids', [uid(name) for name in raw['commit_accounts']])
    return raw


def blocker(actor="alice", rid=1, state="HOLD"):
    return {"actor": actor, "id": rid, "state": state,
            "url": f"https://example/comment/{rid}"}


def actions(rows, roster=("alice", "bob")):
    return M.plan(rows, roster).actions


class RoutingScenarios(unittest.TestCase):
    def test_first_reviews_balance_actual_outstanding_requests_and_planned_work(self):
        rows = [pull(i, requested_reviewers=["alice"]) for i in (10, 11, 12)]
        rows += [pull(20, requested_reviewers=["bob"])]
        rows += [pull(3, created_at=T3), pull(1, created_at=T1), pull(2, created_at=T2)]
        result = M.plan(rows, ["alice", "bob"])
        proposals = [a for a in result.actions if a.assignment is M.Assignment.PROPOSED_USER]
        self.assertEqual([(a.identity.number, a.account) for a in proposals],
                         [(1, "bob"), (2, "bob"), (3, "alice")])
        counts = {load.account: (load.outstanding_requests, load.proposed_requests)
                  for load in result.loads}
        self.assertEqual(counts, {"alice": (3, 1), "bob": (1, 2)})

    def test_all_changed_head_cr_owners_are_routed_separately(self):
        result = actions([pull(reviews=[review("alice"), review("bob", rid=2)])])
        self.assertEqual([(a.reason, a.account, a.review_ids) for a in result],
                         [(M.Reason.CHANGED_HEAD_CR, "alice", (1,)),
                          (M.Reason.CHANGED_HEAD_CR, "bob", (2,))])
        self.assertTrue(all(a.actionable for a in result))

    def test_same_head_cr_awaits_author_without_a_request(self):
        result = actions([pull(reviews=[review(head=HEAD)])])
        self.assertEqual(len(result), 1)
        self.assertEqual((result[0].reason, result[0].account, result[0].actionable),
                         (M.Reason.AWAITING_AUTHOR, "author", False))

    def test_explicit_same_head_rereview_request_is_actionable(self):
        result = actions([pull(requested_reviewers=["alice"], reviews=[review(head=HEAD)])])
        self.assertEqual(len(result), 1)
        self.assertEqual((result[0].reason, result[0].assignment, result[0].actionable),
                         (M.Reason.EXISTING_REQUEST, M.Assignment.EXISTING_USER, True))
        self.assertEqual(result[0].review_ids, (1,))

    def test_different_explicit_request_does_not_resolve_same_head_cr(self):
        result = actions([pull(requested_reviewers=["bob"], reviews=[review(head=HEAD)])])
        self.assertEqual({(a.reason, a.account) for a in result},
                         {(M.Reason.EXISTING_REQUEST, "bob"), (M.Reason.AWAITING_AUTHOR, "author")})

    def test_existing_request_avoids_duplicate_proposal_for_changed_head_owner(self):
        result = actions([pull(requested_reviewers=["ALICE"], reviews=[review("alice")])])
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0].assignment, M.Assignment.EXISTING_USER)

    def test_closed_and_draft_keep_assignment_facts_but_are_not_autoassigned(self):
        result = actions([pull(1, state="closed", requested_reviewers=["alice"]),
                          pull(2, draft=True, requested_teams=["source-review"]),
                          pull(3, draft=True), pull(4, state="closed")])
        self.assertFalse(any(a.actionable for a in result))
        self.assertFalse(any(a.assignment is M.Assignment.PROPOSED_USER for a in result))
        self.assertEqual({a.identity.number for a in result}, {1, 2, 3, 4})
        self.assertIn(M.Assignment.EXISTING_TEAM, [a.assignment for a in result])

    def test_shared_login_is_one_account_and_never_creates_an_extra_reviewer(self):
        result = M.plan([pull(), pull(2)], ["Alice", "alice", "ALICE"])
        self.assertEqual(len(result.loads), 1)
        self.assertEqual(result.loads[0].proposed_requests, 2)
        self.assertEqual({a.account for a in result.actions}, {"Alice"})

    def test_existing_team_request_is_preserved_without_guessing_membership(self):
        result = actions([pull(requested_teams=["reviewers"])])
        self.assertEqual(len(result), 1)
        self.assertEqual((result[0].team, result[0].assignment, result[0].actionable),
                         ("reviewers", M.Assignment.EXISTING_TEAM, True))

    def test_pr_author_is_excluded_case_insensitively(self):
        result = actions([pull(author="ALICE")], roster=["alice", "bob"])
        self.assertEqual(result[0].account, "bob")
        unavailable = actions([pull(author="ALICE")], roster=["alice", "ALICE"])
        self.assertEqual(unavailable[0].reason, M.Reason.NO_REVIEWER)
        self.assertFalse(unavailable[0].actionable)

    def test_commit_actor_is_excluded_case_insensitively(self):
        result = actions([pull(commit_accounts=["ALICE"])])
        self.assertEqual((result[0].account, result[0].reviewer_eligibility),
                         ("bob", M.ReviewerEligibility.ELIGIBLE))
        unavailable = actions([pull(commit_accounts=["alice", "BOB"])])
        self.assertEqual(unavailable[0].reason, M.Reason.NO_REVIEWER)

    def test_commit_actor_id_excludes_same_account_with_a_different_login(self):
        actor_ids = {'author':uid('author'), 'alice':uid('alice'), 'bob':uid('bob'),
                     'old-alice':uid('alice')}
        result = actions([pull(commit_accounts=['old-alice'], commit_actor_ids=[uid('alice')],
                               account_ids=actor_ids)])
        self.assertEqual(result[0].account, 'bob')

    def test_unknown_blocker_and_known_roster_sort_without_losing_owner(self):
        result = actions([pull(blockers=[blocker(actor='unknown')]), pull(2)])
        self.assertIn((M.Reason.AWAITING_OWNER, 'unknown'), {(a.reason, a.account) for a in result})

    def test_unknown_commit_identity_never_proposes_a_reviewer(self):
        result = actions([pull(commit_accounts=["alice"], commit_identities_complete=False)])
        self.assertEqual(result[0].reason, M.Reason.COMMIT_IDENTITY_UNKNOWN)
        self.assertFalse(result[0].actionable)

    def test_conflicting_request_is_preserved_and_independent_reviewer_proposed(self):
        result = actions([pull(requested_reviewers=["Alice"], commit_accounts=["ALICE"])])
        self.assertEqual({(a.reason, a.account, a.reviewer_eligibility) for a in result}, {
            (M.Reason.EXISTING_REQUEST, "alice", M.ReviewerEligibility.COMMIT_ACTOR),
            (M.Reason.INDEPENDENT_REVIEW, "bob", M.ReviewerEligibility.ELIGIBLE)})

    def test_conflicting_cr_owner_remains_owned_alongside_independent_review(self):
        result = actions([pull(reviews=[review("alice")], commit_accounts=["ALICE"])])
        self.assertEqual({(a.reason, a.account) for a in result},
                         {(M.Reason.AWAITING_OWNER, "alice"),
                          (M.Reason.INDEPENDENT_REVIEW, "bob")})

    def test_valid_independent_approval_does_not_displace_conflicting_cr(self):
        row = pull(requested_reviewers=['alice'], reviews=[review('alice')],
                   commit_accounts=['alice'], independent_source_review=True)
        result = actions([row])
        self.assertEqual([(a.reason, a.account, a.review_ids) for a in result],
                         [(M.Reason.EXISTING_REQUEST, 'alice', (1,))])
        self.assertTrue(result[0].to_json()['independent_source_review'])
        self.assertFalse(any(a.assignment is M.Assignment.PROPOSED_USER for a in result))

    def test_current_cr_existing_independent_request_or_team_prevents_extra_request(self):
        rows = [pull(1, reviews=[review(head=HEAD)], commit_accounts=["alice"]),
                pull(2, requested_reviewers=["alice", "bob"], commit_accounts=["alice"]),
                pull(3, requested_reviewers=["alice"], requested_teams=["team"],
                     commit_accounts=["alice"])]
        self.assertFalse(any(a.assignment is M.Assignment.PROPOSED_USER for a in actions(rows)))

    def test_unknown_identity_with_conflicting_request_keeps_it_and_does_not_propose(self):
        result = actions([pull(requested_reviewers=["alice"], commit_accounts=["alice"],
                               commit_identities_complete=False)])
        self.assertEqual({a.reason for a in result},
                         {M.Reason.EXISTING_REQUEST, M.Reason.COMMIT_IDENTITY_UNKNOWN})
        self.assertFalse(any(a.assignment is M.Assignment.PROPOSED_USER for a in result))

    def test_current_head_approval_without_valid_scope_is_routed_for_review(self):
        result = actions([pull(reviews=[review(state="APPROVED", head=HEAD)])])
        self.assertEqual(result[0].reason, M.Reason.REVIEW_NEEDED)
        self.assertEqual(result[0].assignment, M.Assignment.PROPOSED_USER)

    def test_partial_comment_review_does_not_establish_coverage_or_clear_cr(self):
        result = actions([pull(reviews=[review(),
                              review(state="COMMENTED", head=HEAD, at=T2, rid=2)])])
        self.assertEqual(result[0].reason, M.Reason.CHANGED_HEAD_CR)
        self.assertEqual(result[0].review_ids, (1,))
        commented = actions([pull(reviews=[review(state="COMMENTED", head=HEAD)])])
        self.assertEqual(commented[0].reason, M.Reason.REVIEW_NEEDED)

    def test_pending_review_cannot_clear_published_cr(self):
        pending = review(state="PENDING", head=HEAD, at=None, rid=2)
        result = actions([pull(reviews=[review(), pending])])
        self.assertEqual(result[0].reason, M.Reason.CHANGED_HEAD_CR)

    def test_pending_review_disappearing_does_not_imply_completion(self):
        pending = review(state="PENDING", at=None)
        before = M.plan([pull(requested_reviewers=["alice"], reviews=[pending])], ["alice"])
        after = M.plan([pull(requested_reviewers=["alice"], reviews=[])], ["alice"])
        self.assertEqual(before.to_json(), after.to_json())
        self.assertEqual(after.actions[0].reason, M.Reason.EXISTING_REQUEST)

    def test_only_explicit_later_same_keeper_replacement_clears_a_cr(self):
        cr = signed_request()
        self.assertEqual(actions([pull(reviews=[cr, replacement()])])[0].reason, M.Reason.REVIEW_NEEDED)
        for approval in (review(state="APPROVED", head=HEAD, at=T2, rid=2),
                         replacement(keeper="other"), replacement(request=99),
                         review(state="DISMISSED", head=HEAD, at=T2, rid=2)):
            with self.subTest(approval=approval):
                result = actions([pull(reviews=[cr, approval])])
                self.assertEqual((result[0].reason, result[0].account, result[0].review_ids),
                                 (M.Reason.CHANGED_HEAD_CR, "alice", (1,)))
        dismissed = cr | {"state": "DISMISSED"}
        self.assertEqual(actions([pull(reviews=[dismissed])])[0].reason, M.Reason.REVIEW_NEEDED)

    def test_ambiguous_latest_formal_time_or_missing_time_refuses(self):
        for reviews in ([signed_request(), replacement(at=T1)],
                        [review(at=None)],
                        [review(at="invalid")]):
            with self.subTest(reviews=reviews), self.assertRaises(ValueError):
                actions([pull(reviews=reviews)])

    def test_older_tie_cannot_replace_cr_even_after_unrelated_later_approval(self):
        cr = signed_request(at=T1)
        tied = replacement(at=T1)
        latest = replacement(rid=3, request=99, at=T2)
        result = actions([pull(reviews=[cr, tied, latest])])
        self.assertEqual((result[0].reason, result[0].review_ids),
                         (M.Reason.CHANGED_HEAD_CR, (1,)))

    def test_submitted_time_not_id_preserves_later_cr_owner(self):
        later = review("bob", rid=1, at=T2)
        older = review("bob", state="APPROVED", head=HEAD, rid=99, at=T1)
        result = actions([pull(reviews=[later, older])])
        self.assertEqual((result[0].reason, result[0].account, result[0].review_ids),
                         (M.Reason.CHANGED_HEAD_CR, "bob", (1,)))
        result = actions([pull(reviews=(later, older))])
        self.assertEqual((result[0].reason, result[0].account, result[0].review_ids),
                         (M.Reason.CHANGED_HEAD_CR, "bob", (1,)))

    def test_multiple_unresolved_crs_of_same_account_make_one_owned_action(self):
        crs = [signed_request(keeper="one", rid=1), signed_request(keeper="two", rid=2, at=T2)]
        result = actions([pull(reviews=crs)])
        self.assertEqual([(a.reason, a.account, a.review_ids) for a in result],
                         [(M.Reason.CHANGED_HEAD_CR, "alice", (1, 2))])
        current = signed_request(keeper="two", rid=2, at=T2, head=HEAD)
        result = actions([pull(reviews=[crs[0], current])])
        self.assertEqual([(a.reason, a.account, a.review_ids) for a in result],
                         [(M.Reason.AWAITING_AUTHOR, "author", (1, 2))])
        result = actions([pull(reviews=crs + [replacement(request=1, rid=3, at=T3)])])
        self.assertEqual([(a.reason, a.account, a.review_ids) for a in result],
                         [(M.Reason.CHANGED_HEAD_CR, "alice", (2,))])

    def test_same_head_cr_structured_failure_remains_author_action(self):
        formal = {**blocker(state="FAIL"), "kind": "review"}
        result = actions([pull(reviews=[review(head=HEAD)], blockers=[formal])])
        self.assertEqual(len(result), 1)
        self.assertEqual((result[0].reason, result[0].account), (M.Reason.AWAITING_AUTHOR, "author"))
        self.assertEqual(result[0].blockers[0].record_id, 1)

    def test_separate_nonformal_blocker_retains_owner_action_beside_same_head_cr(self):
        comment = {**blocker(state="FAIL"), "kind": "comment"}
        result = actions([pull(reviews=[review(head=HEAD)], blockers=[comment])])
        self.assertEqual({a.reason for a in result}, {M.Reason.AWAITING_OWNER, M.Reason.AWAITING_AUTHOR})

    def test_cr_owner_outside_pool_stays_owned_and_is_not_reassigned(self):
        result = actions([pull(reviews=[review("outside")])])
        self.assertEqual((result[0].reason, result[0].account, result[0].actionable),
                         (M.Reason.AWAITING_OWNER, "outside", False))

    def test_admission_prevents_new_request_but_keeps_explicit_requests(self):
        result = actions([pull(1, admission=True),
                          pull(2, admission=True, requested_reviewers=["bob"], requested_teams=["qa"]),
                          pull(3, admission=True, reviews=[review()])])
        self.assertFalse(any(a.assignment is M.Assignment.PROPOSED_USER for a in result))
        self.assertEqual({(a.identity.number, a.reason) for a in result},
                         {(1, M.Reason.ADMITTED), (2, M.Reason.EXISTING_REQUEST),
                          (3, M.Reason.AWAITING_OWNER)})

    def test_exact_head_structured_refusal_awaits_owner_without_inferred_resolution(self):
        result = actions([pull(reviews=[review(), review("bob", state="APPROVED", head=HEAD, rid=2)],
                               blockers=[blocker()])])
        self.assertEqual(len(result), 1)
        self.assertEqual((result[0].reason, result[0].account, result[0].actionable),
                         (M.Reason.AWAITING_OWNER, "alice", False))
        self.assertEqual(result[0].review_ids, (1,))

    def test_structured_fail_owner_can_rereview_when_explicitly_requested(self):
        result = actions([pull(requested_reviewers=["alice"], blockers=[blocker(state="FAIL")])])
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0].reason, M.Reason.EXISTING_REQUEST)
        self.assertTrue(result[0].actionable)
        self.assertEqual(result[0].blockers[0].state, M.BlockerState.FAIL)

    def test_multiple_blockers_same_account_form_one_owned_action(self):
        result = actions([pull(blockers=[blocker(rid=1), blocker(rid=2)])])
        self.assertEqual(len(result), 1)
        self.assertEqual(len(result[0].blockers), 2)

    def test_missing_blocker_identity_cannot_be_assigned_to_an_unrelated_account(self):
        result = actions([pull(blockers=[blocker(actor=None)])])
        self.assertEqual((result[0].reason, result[0].account), (M.Reason.AWAITING_OWNER, None))
        self.assertFalse(result[0].actionable)

    def test_ownership_proposals_contribute_to_first_review_load(self):
        result = actions([pull(1, reviews=[review("alice")]), pull(2)])
        assigned = {a.identity.number: a.account for a in result}
        self.assertEqual(assigned, {1: "alice", 2: "bob"})

    def test_existing_assignment_outside_roster_is_preserved(self):
        result = M.plan([pull(requested_reviewers=["external"])], ["alice"])
        self.assertEqual(result.actions[0].account, "external")
        self.assertTrue(result.actions[0].actionable)
        self.assertFalse(next(a for a in result.loads if a.account == "external").in_pool)

    def test_head_base_and_stack_identity_survive_every_action(self):
        stack = {"number": 7, "position": 1, "size": 2, "base": "main"}
        raw = pull(base_ref="stack-layer", stack=stack, requested_reviewers=["alice"],
                   reviews=[review("bob")])
        result = M.plan([raw], ["alice", "bob"])
        for action in result.to_json()["actions"]:
            self.assertEqual((action["head"], action["base_ref"], action["base_sha"], action["stack"]),
                             (HEAD, "stack-layer", BASE, stack))
        json.dumps(result.to_json())

    def test_input_order_does_not_change_oldest_first_work_assignment(self):
        rows = [pull(2, created_at=T2), pull(1, created_at=T1)]
        self.assertEqual(M.plan(rows, ["alice", "bob"]).to_json(),
                         M.plan(list(reversed(rows)), ["alice", "bob"]).to_json())

    def test_inputs_are_not_mutated_and_returned_identity_is_frozen(self):
        raw = pull(stack={"number": 5})
        original = copy.deepcopy(raw)
        result = M.plan([raw], ["alice"])
        self.assertEqual(raw, original)
        raw["stack"]["number"] = 99
        self.assertEqual(result.actions[0].to_json()["stack"], {"number": 5})

    def test_unknown_or_malformed_typed_inputs_fail_instead_of_empty_work(self):
        bad_rows = [pull(state="merged"), pull(draft="false"), pull(admission=1),
                    pull(reviews=[review(state="FUTURE_STATE")]), pull(head="bad"),
                    pull(blockers=[blocker(state="PASS")]), pull(requested_reviewers="alice"),
                    pull(reviews=[review(actor="")]), pull(created_at="yesterday"),
                    pull(blockers=[{"state": "HOLD"}])]
        missing = pull()
        missing.pop("admission")
        bad_rows.append(missing)
        for row in bad_rows:
            with self.subTest(row=row), self.assertRaises(ValueError):
                M.plan([row], ["alice"])
        with self.assertRaises(ValueError):
            M.plan([pull(), pull()], ["alice"])
        with self.assertRaises(ValueError):
            M.plan([], [None])


if __name__ == "__main__":
    unittest.main()
