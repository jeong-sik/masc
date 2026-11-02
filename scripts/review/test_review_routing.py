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
            "author_association": "MEMBER",
            "commit_id": head, "submitted_at": at, "body": "source findings"}


def pull(number=1, **changes):
    raw = {"number": number, "title": f"Fix {number}", "url": f"https://example/pull/{number}",
           "state": "open", "draft": False, "author": "author", "head": HEAD,
           "base_ref": "main", "base_sha": BASE, "stack": None, "created_at": T1,
           "requested_reviewers": [], "requested_teams": [], "reviews": []}
    raw.update(changes)
    names = [raw['author'], 'alice', 'bob', *raw['requested_reviewers']]
    raw.setdefault('account_ids', {name.casefold():uid(name) for name in names})
    raw.setdefault('author_id', uid(raw['author']))
    return raw


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

    def test_non_author_can_receive_review_request(self):
        result = actions([pull()])
        self.assertEqual((result[0].account, result[0].reviewer_eligibility),
                         ("alice", M.ReviewerEligibility.ELIGIBLE))

    def test_pr_author_request_is_preserved_and_another_reviewer_proposed(self):
        result = actions([pull(author="Alice", requested_reviewers=["Alice"])])
        self.assertEqual({(a.reason, a.account, a.reviewer_eligibility) for a in result}, {
            (M.Reason.EXISTING_REQUEST, "alice", M.ReviewerEligibility.PR_AUTHOR),
            (M.Reason.NON_AUTHOR_REVIEW, "bob", M.ReviewerEligibility.ELIGIBLE)})

    def test_changed_head_cr_returns_to_owner(self):
        result = actions([pull(reviews=[review("alice")])])
        self.assertEqual({(a.reason, a.account) for a in result},
                         {(M.Reason.CHANGED_HEAD_CR, "alice")})

    def test_native_approval_does_not_displace_another_accounts_cr(self):
        row = pull(author='alice', requested_reviewers=['alice'], reviews=[review('alice'),
                   review('bob', state='APPROVED', head=HEAD, rid=2)])
        result = actions([row])
        self.assertEqual([(a.reason, a.account, a.review_ids) for a in result],
                         [(M.Reason.EXISTING_REQUEST, 'alice', (1,))])
        self.assertEqual(result[0].to_json()['approval_ids'], [2])
        self.assertFalse(any(a.assignment is M.Assignment.PROPOSED_USER for a in result))

    def test_same_head_other_accounts_cr_still_waits_for_author(self):
        cr = review('alice', head=HEAD)
        approved = review('bob', state='APPROVED', head=HEAD, rid=2)
        [action] = actions([pull(reviews=[cr, approved])])
        self.assertEqual((action.reason, action.account, action.review_ids, action.approval_ids),
                         (M.Reason.AWAITING_AUTHOR, 'author', (1,), (2,)))

    def test_same_account_old_head_approval_clears_cr_but_not_new_head_review(self):
        cr = review('alice')
        approved = review('alice', state='APPROVED', head=OLD, rid=2, at=T2)
        [action] = actions([pull(reviews=[cr, approved])])
        self.assertEqual((action.reason, action.approval_ids, action.review_ids),
                         (M.Reason.REVIEW_NEEDED, (), ()))
        self.assertEqual(action.to_json()['superseded_change_requests'][0]['finding_resolution'],
                         'unverified')

    def test_new_cr_stays_active_and_previously_superseded_cr_stays_in_history(self):
        earlier = review('alice', rid=1, at=T1)
        approved = review('alice', state='APPROVED', head=HEAD, rid=2, at=T2)
        later = review('alice', rid=3, at=T3)
        [action] = actions([pull(reviews=[earlier, approved, later])])
        self.assertEqual((action.reason, action.review_ids, action.approval_ids),
                         (M.Reason.CHANGED_HEAD_CR, (3,), ()))
        self.assertEqual(action.to_json()['superseded_change_requests'], [{
            'review_id':1, 'account_id':uid('alice'), 'observed_login':'alice',
            'finding_resolution':'unverified'}])

    def test_current_cr_existing_independent_request_or_team_prevents_extra_request(self):
        rows = [pull(1, reviews=[review(head=HEAD)]),
                pull(2, requested_reviewers=["alice", "bob"]),
                pull(3, requested_reviewers=["alice"], requested_teams=["team"])]
        self.assertFalse(any(a.assignment is M.Assignment.PROPOSED_USER for a in actions(rows)))

    def test_existing_request_is_not_duplicated(self):
        result = actions([pull(requested_reviewers=["alice"])])
        self.assertEqual({a.reason for a in result}, {M.Reason.EXISTING_REQUEST})
        self.assertFalse(any(a.assignment is M.Assignment.PROPOSED_USER for a in result))

    def test_current_head_native_approval_needs_no_body_format(self):
        result = actions([pull(reviews=[review(state="APPROVED", head=HEAD)])])
        self.assertEqual(result[0].reason, M.Reason.APPROVED)
        self.assertEqual(result[0].approval_ids, (1,))
        self.assertEqual(result[0].assignment, M.Assignment.NONE)

    def test_native_approval_does_not_require_author_association(self):
        base = review(state="APPROVED", head=HEAD)
        missing = {key:value for key, value in base.items() if key != 'author_association'}
        for approved in (missing, base | {"author_association":"NONE"}):
            with self.subTest(approved=approved):
                [action] = actions([pull(reviews=[approved])])
                self.assertEqual(action.reason, M.Reason.APPROVED)
                self.assertEqual(action.approval_ids, (1,))

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

    def test_nonformal_review_metadata_does_not_block_current_approval(self):
        approved = review(state="APPROVED", head=HEAD, rid=2, at=T2)
        comment = review(state="COMMENTED", rid=1) | {
            "user": None, "commit_id": None, "submitted_at": None,
            "body": "A regular comment."}
        row = pull(reviews=[approved])
        row["reviews"].append(comment)
        result = actions([row])
        self.assertEqual((result[0].reason, result[0].approval_ids), (M.Reason.APPROVED, (2,)))

    def test_cr_without_a_commit_id_remains_visible_without_guessing_changed_head(self):
        result = actions([pull(reviews=[review() | {"commit_id": None}])])
        self.assertEqual((result[0].reason, result[0].account, result[0].review_ids),
                         (M.Reason.AWAITING_OWNER, None, (1,)))
        self.assertEqual(result[0].to_json()['review_authors'],
                         [{'account_id':uid('alice'), 'observed_login':'alice'}])
        self.assertFalse(result[0].actionable)

    def test_renamed_account_approval_replaces_its_own_older_cr(self):
        cr = review('old-alice') | {'user': {'login':'old-alice', 'id':uid('alice')}}
        approved = review('alice', state='APPROVED', head=HEAD, rid=2, at=T2)
        result = actions([pull(reviews=[cr, approved])])
        self.assertEqual((result[0].reason, result[0].approval_ids), (M.Reason.APPROVED, (2,)))
        self.assertEqual(result[0].to_json()['superseded_change_requests'], [{
            'review_id':1, 'account_id':uid('alice'), 'observed_login':'old-alice',
            'finding_resolution':'unverified'}])

    def test_renamed_cr_owner_routes_to_current_verified_roster_login(self):
        cr = review('old-alice') | {'user': {'login':'old-alice', 'id':uid('alice')}}
        result = actions([pull(reviews=[cr])])
        self.assertEqual((result[0].reason, result[0].account, result[0].account_id),
                         (M.Reason.CHANGED_HEAD_CR, 'alice', uid('alice')))
        self.assertEqual(result[0].to_json()['review_authors'],
                         [{'account_id':uid('alice'), 'observed_login':'old-alice'}])

    def test_reused_historical_login_never_routes_cr_to_new_account(self):
        cr = review('alice') | {'user': {'login':'alice', 'id':uid('outside')}}
        result = actions([pull(reviews=[cr])])
        self.assertEqual((result[0].reason, result[0].account, result[0].actionable),
                         (M.Reason.AWAITING_OWNER, None, False))
        self.assertEqual(result[0].to_json()['review_authors'],
                         [{'account_id':uid('outside'), 'observed_login':'alice'}])

    def test_reused_login_approval_does_not_clear_the_old_accounts_cr(self):
        cr = review('alice') | {'user': {'login':'alice', 'id':uid('outside')}}
        approved = review('alice', state='APPROVED', head=HEAD, rid=2, at=T2)
        [action] = actions([pull(reviews=[cr, approved])])
        self.assertEqual((action.reason, action.account, action.review_ids, action.approval_ids),
                         (M.Reason.AWAITING_OWNER, None, (1,), (2,)))
        self.assertEqual(action.to_json()['superseded_change_requests'], [])

    def test_current_request_matches_renamed_cr_owner_by_account_id(self):
        cr = review('old-alice') | {'user': {'login':'old-alice', 'id':uid('alice')}}
        [action] = actions([pull(reviews=[cr], requested_reviewers=['alice'])])
        self.assertEqual((action.reason, action.account, action.review_ids),
                         (M.Reason.EXISTING_REQUEST, 'alice', (1,)))

    def test_latest_same_account_approval_or_dismissal_replaces_cr(self):
        cr = review()
        approval = review(state="APPROVED", head=HEAD, at=T2, rid=2)
        self.assertEqual(actions([pull(reviews=[cr, approval])])[0].reason, M.Reason.APPROVED)
        dismissed = review(state="DISMISSED", head=HEAD, at=T2, rid=2)
        self.assertEqual(actions([pull(reviews=[cr, dismissed])])[0].reason, M.Reason.REVIEW_NEEDED)
        dismissed = cr | {"state": "DISMISSED"}
        self.assertEqual(actions([pull(reviews=[dismissed])])[0].reason, M.Reason.REVIEW_NEEDED)

    def test_missing_or_invalid_latest_formal_time_refuses(self):
        for reviews in ([review(at=None)],
                        [review(at="invalid")]):
            with self.subTest(reviews=reviews), self.assertRaises(ValueError):
                actions([pull(reviews=reviews)])

    def test_same_head_approvals_at_same_time_are_not_ambiguous(self):
        one = review(state='APPROVED', head=HEAD, rid=1, at=T1)
        two = review(state='APPROVED', head=HEAD, rid=2, at=T1)
        [action] = actions([pull(reviews=[one, two])])
        self.assertEqual((action.reason, action.approval_ids), (M.Reason.APPROVED, (1, 2)))
        self.assertEqual(action.to_json()['ambiguous_review_ids'], [])

    def test_same_head_change_requests_at_same_time_route_once(self):
        one = review(rid=1, at=T1)
        two = review(rid=2, at=T1)
        [action] = actions([pull(reviews=[one, two])])
        self.assertEqual((action.reason, action.account, action.review_ids),
                         (M.Reason.CHANGED_HEAD_CR, 'alice', (1, 2)))
        self.assertEqual(action.to_json()['ambiguous_review_ids'], [])

    def test_conflicting_tied_reviews_are_visible_without_stalling_another_pr(self):
        cr = review('alice', rid=1, at=T1)
        approval = review('alice', state='APPROVED', head=HEAD, rid=2, at=T1)
        result = actions([pull(1, reviews=[cr, approval]), pull(2)])
        first = [a for a in result if a.identity.number == 1]
        self.assertEqual(len(first), 1)
        self.assertEqual((first[0].reason, first[0].actionable), (M.Reason.AMBIGUOUS_REVIEW, False))
        self.assertEqual(first[0].to_json()['ambiguous_review_ids'], [1, 2])
        self.assertEqual([r['state'] for r in first[0].to_json()['ambiguous_reviews']],
                         ['CHANGES_REQUESTED', 'APPROVED'])
        self.assertEqual([(a.reason, a.assignment) for a in result if a.identity.number == 2],
                         [(M.Reason.FIRST_REVIEW, M.Assignment.PROPOSED_USER)])

    def test_ambiguous_account_does_not_suppress_other_accounts_real_cr(self):
        cr = review('alice', rid=1, at=T1)
        approval = review('alice', state='APPROVED', head=HEAD, rid=2, at=T1)
        other_cr = review('bob', rid=3, at=T2)
        result = actions([pull(reviews=[cr, approval, other_cr])])
        self.assertEqual({(a.reason, a.account) for a in result}, {
            (M.Reason.AMBIGUOUS_REVIEW, None), (M.Reason.CHANGED_HEAD_CR, 'bob')})

    def test_explicit_request_remains_visible_with_ambiguous_review(self):
        cr = review('alice', rid=1, at=T1)
        approval = review('alice', state='APPROVED', head=HEAD, rid=2, at=T1)
        result = actions([pull(reviews=[cr, approval], requested_reviewers=['alice'])])
        self.assertEqual({(a.reason, a.account) for a in result}, {
            (M.Reason.AMBIGUOUS_REVIEW, None), (M.Reason.EXISTING_REQUEST, 'alice')})
        self.assertFalse(any(a.assignment is M.Assignment.PROPOSED_USER for a in result))

    def test_tied_approvals_on_different_heads_are_reported_as_ambiguous(self):
        one = review(state='APPROVED', head=HEAD, rid=1, at=T1)
        two = review(state='APPROVED', head=OLD, rid=2, at=T1)
        [action] = actions([pull(reviews=[one, two])])
        self.assertEqual((action.reason, action.approval_ids), (M.Reason.AMBIGUOUS_REVIEW, ()))
        self.assertEqual(action.to_json()['ambiguous_review_ids'], [1, 2])

    def test_tied_change_requests_on_different_heads_both_remain_visible(self):
        one = review(head=OLD, rid=1, at=T1)
        two = review(head=HEAD, rid=2, at=T1)
        [action] = actions([pull(reviews=[one, two])])
        self.assertEqual(action.reason, M.Reason.AMBIGUOUS_REVIEW)
        self.assertEqual([r['state'] for r in action.to_json()['ambiguous_reviews']],
                         ['CHANGES_REQUESTED', 'CHANGES_REQUESTED'])
        self.assertEqual([r['head'] for r in action.to_json()['ambiguous_reviews']], [OLD, HEAD])
        self.assertFalse(action.actionable)

    def test_other_accounts_approval_remains_visible_beside_ambiguous_state(self):
        one = review('alice', state='APPROVED', head=HEAD, rid=1, at=T1)
        two = review('alice', state='DISMISSED', head=HEAD, rid=2, at=T1)
        approved = review('bob', state='APPROVED', head=HEAD, rid=3, at=T1)
        for requests in ({}, {'requested_reviewers':['alice'], 'requested_teams':['qa']}):
            with self.subTest(requests=requests):
                result = actions([pull(reviews=[one, two, approved], **requests)])
                by_reason = {a.reason: a for a in result}
                self.assertEqual((by_reason[M.Reason.AMBIGUOUS_REVIEW].approval_ids,
                                  by_reason[M.Reason.APPROVED].approval_ids), ((3,), (3,)))
                self.assertEqual(by_reason[M.Reason.AMBIGUOUS_REVIEW].to_json()['ambiguous_review_ids'], [1, 2])
                self.assertFalse(any(a.assignment is M.Assignment.PROPOSED_USER for a in result))
                if requests:
                    existing = [a for a in result if a.reason is M.Reason.EXISTING_REQUEST]
                    self.assertEqual({a.assignment for a in existing},
                                     {M.Assignment.EXISTING_USER, M.Assignment.EXISTING_TEAM})
        actual_cr = review('carol', rid=4, at=T2)
        result = actions([pull(reviews=[one, two, approved, actual_cr])])
        self.assertNotIn(M.Reason.APPROVED, {a.reason for a in result})
        owner_action = next(a for a in result if a.reason is M.Reason.AWAITING_OWNER)
        self.assertEqual(owner_action.review_ids, (4,))

    def test_older_tie_does_not_hide_an_unambiguous_latest_approval(self):
        cr = review(at=T1)
        tied = review(state='APPROVED', head=HEAD, rid=2, at=T1)
        latest = review(state='APPROVED', head=HEAD, rid=3, at=T2)
        result = actions([pull(reviews=[cr, tied, latest])])
        self.assertEqual((result[0].reason, result[0].approval_ids),
                         (M.Reason.APPROVED, (3,)))

    def test_submitted_time_not_id_preserves_later_cr_owner(self):
        later = review("bob", rid=1, at=T2)
        older = review("bob", state="APPROVED", head=HEAD, rid=99, at=T1)
        result = actions([pull(reviews=[later, older])])
        self.assertEqual((result[0].reason, result[0].account, result[0].review_ids),
                         (M.Reason.CHANGED_HEAD_CR, "bob", (1,)))
        result = actions([pull(reviews=(later, older))])
        self.assertEqual((result[0].reason, result[0].account, result[0].review_ids),
                         (M.Reason.CHANGED_HEAD_CR, "bob", (1,)))

    def test_latest_cr_of_same_account_is_the_only_outstanding_one(self):
        crs = [review(rid=1), review(rid=2, at=T2)]
        result = actions([pull(reviews=crs)])
        self.assertEqual([(a.reason, a.account, a.review_ids) for a in result],
                         [(M.Reason.CHANGED_HEAD_CR, "alice", (2,))])
        current = review(rid=2, at=T2, head=HEAD)
        result = actions([pull(reviews=[crs[0], current])])
        self.assertEqual([(a.reason, a.account, a.review_ids) for a in result],
                         [(M.Reason.AWAITING_AUTHOR, "author", (2,))])
        result = actions([pull(reviews=crs + [review(state='APPROVED', head=HEAD, rid=3, at=T3)])])
        self.assertEqual([(a.reason, a.account, a.review_ids) for a in result],
                         [(M.Reason.APPROVED, None, ())])

    def test_cr_owner_outside_pool_stays_owned_and_is_not_reassigned(self):
        result = actions([pull(reviews=[review("outside")])])
        self.assertEqual((result[0].reason, result[0].account, result[0].actionable),
                         (M.Reason.AWAITING_OWNER, None, False))
        self.assertEqual(result[0].to_json()['review_authors'],
                         [{'account_id':uid('outside'), 'observed_login':'outside'}])

    def test_approval_keeps_existing_requests_and_other_accounts_cr(self):
        approved = review("bob", state="APPROVED", head=HEAD, rid=2)
        result = actions([pull(1, reviews=[approved]),
                          pull(2, reviews=[approved], requested_reviewers=["bob"], requested_teams=["qa"]),
                          pull(3, reviews=[review(), approved])])
        self.assertEqual({(a.identity.number, a.reason) for a in result},
                         {(1, M.Reason.APPROVED), (2, M.Reason.EXISTING_REQUEST), (2, M.Reason.APPROVED),
                          (3, M.Reason.CHANGED_HEAD_CR)})

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

    def test_changed_cr_first_then_oldest_new_or_rereview(self):
        older = pull(1, created_at=T1, reviews=[review(state="COMMENTED")])
        newer = pull(2, created_at=T2)
        changed_cr = pull(3, created_at=T3, reviews=[review("bob")])
        result = M.plan([newer, changed_cr, older], ["alice", "bob"])
        self.assertEqual([(a.identity.number, a.reason) for a in result.actions], [
            (3, M.Reason.CHANGED_HEAD_CR),
            (1, M.Reason.REVIEW_NEEDED),
            (2, M.Reason.FIRST_REVIEW)])

    def test_inputs_are_not_mutated_and_returned_identity_is_frozen(self):
        raw = pull(stack={"number": 5})
        original = copy.deepcopy(raw)
        result = M.plan([raw], ["alice"])
        self.assertEqual(raw, original)
        raw["stack"]["number"] = 99
        self.assertEqual(result.actions[0].to_json()["stack"], {"number": 5})

    def test_unknown_or_malformed_typed_inputs_fail_instead_of_empty_work(self):
        bad_rows = [pull(state="merged"), pull(draft="false"),
                    pull(reviews=[review(state="FUTURE_STATE")]), pull(head="bad"),
                    pull(requested_reviewers="alice"),
                    pull(reviews=[review(actor="")]), pull(created_at="yesterday")]
        missing = pull()
        missing.pop("reviews")
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
