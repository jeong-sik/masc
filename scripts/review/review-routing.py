#!/usr/bin/env python3
"""Pure review routing from GitHub assignments and submitted reviews.

The plan proposes requests, never claims reviews have started or completed.
All network reads and writes belong to the caller. A current-head approval is
a GitHub account fact; it does not prove session independence or CI status.
"""
from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
from enum import Enum
import importlib.util
import json
from pathlib import Path
import re
import sys
from typing import Sequence


HERE = Path(__file__).resolve().parent


def _load_review_helper(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


github_reviews = _load_review_helper("routing_github_reviews", "github-reviews.py")


class Reason(str, Enum):
    EXISTING_REQUEST = "existing_request"
    AMBIGUOUS_REVIEW = "ambiguous_review"
    CHANGED_HEAD_CR = "changed_head_cr"
    AWAITING_AUTHOR = "awaiting_author"
    AWAITING_OWNER = "awaiting_owner"
    FIRST_REVIEW = "first_review"
    REVIEW_NEEDED = "review_needed"
    NON_AUTHOR_REVIEW = "non_author_review"
    APPROVED = "approved"
    DRAFT = "draft"
    CLOSED = "closed"
    NO_REVIEWER = "no_reviewer"


class Assignment(str, Enum):
    EXISTING_USER = "existing_user"
    EXISTING_TEAM = "existing_team"
    PROPOSED_USER = "proposed_user"
    NONE = "none"


class PullState(str, Enum):
    OPEN = "open"
    CLOSED = "closed"


class ReviewState(str, Enum):
    APPROVED = "APPROVED"
    CHANGES_REQUESTED = "CHANGES_REQUESTED"
    DISMISSED = "DISMISSED"
    COMMENTED = "COMMENTED"
    PENDING = "PENDING"


class ReviewerEligibility(str, Enum):
    ELIGIBLE = "eligible"
    PR_AUTHOR = "pr_author"
    UNKNOWN = "unknown"


@dataclass(frozen=True)
class Identity:
    number: int
    title: str
    url: str
    head: str
    base_ref: str
    base_sha: str
    stack_json: str
    created_at: datetime

    def to_json(self) -> dict:
        return {"number": self.number, "title": self.title, "url": self.url,
                "head": self.head, "base_ref": self.base_ref, "base_sha": self.base_sha,
                "stack": json.loads(self.stack_json),
                "created_at": self.created_at.isoformat()}


@dataclass(frozen=True)
class Review:
    actor: str
    actor_id: int
    review_id: int
    state: ReviewState
    head: str | None
    submitted_at: datetime


@dataclass(frozen=True)
class ReviewSubmission:
    review_id: int
    state: ReviewState
    head: str
    observed_login: str | None
    account_id: int | None
    submitted_at: str | None

    def to_json(self) -> dict:
        return {"review_id": self.review_id, "state": self.state.value,
                "head": self.head, "observed_login": self.observed_login,
                "account_id": self.account_id, "submitted_at": self.submitted_at}


@dataclass(frozen=True)
class Pull:
    identity: Identity
    state: PullState
    draft: bool
    author: str
    author_id: int
    requested_reviewers: tuple[str, ...]
    requested_teams: tuple[str, ...]
    account_ids: tuple[tuple[str, int], ...]
    reviews: tuple[Review, ...]
    has_submitted_review: bool
    unresolved_cr_ids: frozenset[int]
    approval_ids: tuple[int, ...]
    ambiguous_reviews: tuple[Review, ...]
    superseded_change_requests: tuple[tuple[int, int, str], ...]
    current_head_submissions: tuple[ReviewSubmission, ...]


@dataclass(frozen=True)
class Action:
    identity: Identity
    reason: Reason
    assignment: Assignment
    account: str | None = None
    account_id: int | None = None
    team: str | None = None
    actionable: bool = False
    reviewer_eligibility: ReviewerEligibility | None = None
    approval_ids: tuple[int, ...] = ()
    ambiguous_reviews: tuple[Review, ...] = ()
    superseded_change_requests: tuple[tuple[int, int, str], ...] = ()
    review_ids: tuple[int, ...] = ()
    review_authors: tuple[tuple[int, str], ...] = ()
    current_head_submissions: tuple[ReviewSubmission, ...] = ()

    def to_json(self) -> dict:
        return {**self.identity.to_json(), "reason": self.reason.value,
                "assignment": self.assignment.value, "account": self.account,
                "account_id": self.account_id,
                "team": self.team, "actionable": self.actionable,
                "reviewer_eligibility": (self.reviewer_eligibility.value
                                         if self.reviewer_eligibility else None),
                "approval_ids": list(self.approval_ids),
                "ambiguous_review_ids": [r.review_id for r in self.ambiguous_reviews],
                "ambiguous_reviews": [
                    {"review_id": r.review_id, "account_id": r.actor_id,
                     "observed_login": r.actor, "state": r.state.value,
                     "head": r.head, "submitted_at": r.submitted_at.isoformat()}
                    for r in self.ambiguous_reviews],
                "superseded_change_requests": [
                    {"review_id": rid, "account_id": actor_id, "observed_login": actor,
                     "finding_resolution": "unverified"}
                    for rid, actor_id, actor in self.superseded_change_requests],
                "review_ids": list(self.review_ids),
                "review_authors": [{"account_id": actor_id, "observed_login": actor}
                                   for actor_id, actor in self.review_authors],
                "current_head_submissions": [r.to_json() for r in self.current_head_submissions]}


@dataclass(frozen=True)
class AccountLoad:
    account: str
    in_pool: bool
    outstanding_requests: int
    proposed_requests: int
    actions: tuple[Action, ...]

    def to_json(self) -> dict:
        return {"account": self.account, "in_pool": self.in_pool,
                "outstanding_requests": self.outstanding_requests,
                "proposed_requests": self.proposed_requests,
                "actions": [a.to_json() for a in self.actions]}


@dataclass(frozen=True)
class Worklist:
    actions: tuple[Action, ...]
    loads: tuple[AccountLoad, ...]

    def to_json(self) -> dict:
        return {"actions": [a.to_json() for a in self.actions],
                "accounts": [load.to_json() for load in self.loads]}


def text(value: object, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{field} must be a nonempty string")
    return value


def login(value: object, field: str) -> str:
    result = text(value, field)
    if any(c.isspace() for c in result):
        raise ValueError(f"{field} must be a GitHub login")
    return result


def sequence(value: object, field: str) -> Sequence:
    if not isinstance(value, (list, tuple)):
        raise ValueError(f"{field} must be an array")
    return value


def boolean(value: object, field: str) -> bool:
    if type(value) is not bool:
        raise ValueError(f"{field} must be boolean")
    return value


def positive_id(value: object, field: str) -> int:
    if type(value) is not int or value < 1:
        raise ValueError(f"{field} must be a positive integer")
    return value


def sha(value: object, field: str) -> str:
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{40}", value) is None:
        raise ValueError(f"{field} must be a lowercase 40-character SHA")
    return value


def instant(value: object, field: str) -> datetime:
    try:
        result = datetime.fromisoformat(text(value, field).replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError(f"invalid {field}") from exc
    if result.tzinfo is None:
        raise ValueError(f"{field} must include a timezone")
    return result.astimezone(timezone.utc)


def unique_logins(values: object, field: str) -> tuple[str, ...]:
    result = {}
    for value in sequence(values, field):
        actor = login(value, field)
        result.setdefault(actor.casefold(), actor)
    return tuple(result.values())


def frozen_json(value: object, field: str) -> str:
    try:
        return json.dumps(value, allow_nan=False, sort_keys=True)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{field} must contain JSON data") from exc


def parse_review(raw: object) -> Review | None:
    if not isinstance(raw, dict):
        raise ValueError("review must be an API object")
    try:
        state = ReviewState(raw.get("state"))
    except (ValueError, TypeError) as exc:
        raise ValueError("unknown review state") from exc
    if state in (ReviewState.PENDING, ReviewState.COMMENTED):
        return None
    user = raw.get("user")
    if not isinstance(user, dict):
        raise ValueError("review.user must be an API object")
    return Review(login(user.get("login"), "review.user.login"),
                  positive_id(user.get("id"), "review.user.id"),
                  positive_id(raw.get("id"), "review.id"), state,
                  (None if raw.get("commit_id") is None else
                   sha(raw.get("commit_id"), "review.commit_id")),
                  instant(raw.get("submitted_at"), "review.submitted_at"))


def current_head_submissions(records: Sequence[dict], head: str) -> tuple[ReviewSubmission, ...]:
    # The native evaluator has checked record IDs and states. Keep comments as
    # observations, outside its formal decisions. Missing comment metadata must
    # not block routing or turn an unknown account into a roster identity.
    result = []
    for raw in records:
        state = ReviewState(raw["state"])
        if state is ReviewState.PENDING or raw.get("commit_id") != head:
            continue
        user = raw.get("user")
        user = user if isinstance(user, dict) else {}
        actor, actor_id, when = user.get("login"), user.get("id"), raw.get("submitted_at")
        result.append(ReviewSubmission(
            raw["id"], state, head,
            actor if isinstance(actor, str) and actor.strip() else None,
            actor_id if type(actor_id) is int and actor_id > 0 else None,
            when if isinstance(when, str) else None))
    return tuple(result)


def parse_pull(raw: object) -> Pull:
    if not isinstance(raw, dict):
        raise ValueError("pull must be an object")
    required = {"number", "title", "url", "state", "draft", "author", "head",
                "base_ref", "base_sha", "stack", "created_at", "requested_reviewers",
                "requested_teams", "author_id", "account_ids", "reviews"}
    missing = required.difference(raw)
    if missing:
        raise ValueError("pull missing fields: " + ",".join(sorted(missing)))
    try:
        state = PullState(raw["state"])
    except (ValueError, TypeError) as exc:
        raise ValueError("unknown pull state") from exc
    stack = raw["stack"]
    if stack is not None and not isinstance(stack, dict):
        raise ValueError("stack must be an object or null")
    identity = Identity(positive_id(raw["number"], "number"), text(raw["title"], "title"),
                        text(raw["url"], "url"), sha(raw["head"], "head"),
                        text(raw["base_ref"], "base_ref"),
                        sha(raw["base_sha"], "base_sha"),
                        frozen_json(stack, "stack"),
                        instant(raw["created_at"], "created_at"))
    review_records = sequence(raw["reviews"], "reviews")
    # GitHub accounts, not body signatures, define the latest formal review.
    review_state = github_reviews.evaluate(
        {"number": identity.number, "user": {"id": raw["author_id"]},
         "head": {"sha": identity.head}}, list(review_records), head=identity.head)
    unresolved = frozenset(cr["id"] for cr in review_state["change_requests"])
    has_submitted_review = any(r["state"] != "PENDING" for r in review_records)
    reviews = tuple(r for r in (parse_review(r) for r in review_records)
                    if r is not None)
    by_review_id = {r.review_id: r for r in reviews}
    ambiguous = tuple(by_review_id[rid] for rid in review_state["ambiguous_review_ids"])
    superseded = tuple((cr["id"], by_review_id[cr["id"]].actor_id, cr["login"])
                       for cr in review_state["superseded_change_requests"])
    if not isinstance(raw["account_ids"], dict):
        raise ValueError("account_ids must be an object")
    accounts = tuple((login(name, "account_ids").casefold(), positive_id(value, "account_ids"))
                     for name, value in raw["account_ids"].items())
    if len({name for name, _ in accounts}) != len(accounts):
        raise ValueError("duplicate account identity")
    author = login(raw["author"], "author")
    author_id = positive_id(raw["author_id"], "author_id")
    known = dict(accounts)
    if known.get(author.casefold()) != author_id:
        raise ValueError("account identity does not match author")
    return Pull(identity, state, boolean(raw["draft"], "draft"), author, author_id,
                unique_logins(raw["requested_reviewers"], "requested_reviewers"),
                unique_logins(raw["requested_teams"], "requested_teams"),
                accounts, reviews, has_submitted_review, unresolved,
                tuple(review_state["approval_ids"]), ambiguous,
                superseded, current_head_submissions(review_records, identity.head))


def reviewer_eligibility(pull: Pull, account: str) -> ReviewerEligibility:
    key = account.casefold()
    actor_id = dict(pull.account_ids).get(key)
    if actor_id is None:
        return ReviewerEligibility.UNKNOWN
    if actor_id == pull.author_id:
        return ReviewerEligibility.PR_AUTHOR
    return ReviewerEligibility.ELIGIBLE


def current_crs(pull: Pull) -> tuple[Review, ...]:
    return tuple(sorted((r for r in pull.reviews if r.review_id in pull.unresolved_cr_ids),
                        key=lambda r: (r.actor.casefold(), r.review_id)))


def plan(snapshot: Sequence[dict], roster: Sequence[str]) -> Worklist:
    """Return exact-scope proposed and existing work without changing inputs."""
    pool = unique_logins(roster, "roster")
    pulls = tuple(parse_pull(raw) for raw in sequence(snapshot, "snapshot"))
    if len({p.identity.number for p in pulls}) != len(pulls):
        raise ValueError("snapshot contains duplicate pull numbers")
    identities = {}
    for pull in pulls:
        for name, actor_id in pull.account_ids:
            if name in identities and identities[name] != actor_id:
                raise ValueError("account identity changed during snapshot")
            identities[name] = actor_id

    def key(actor):
        return identities.get(actor.casefold(), "login:" + actor.casefold())

    pool_keys = {key(a) for a in pool}
    canonical = {key(actor): actor for actor in pool}
    outstanding: Counter = Counter()
    proposed: Counter = Counter()
    for pull in pulls:
        if pull.state is PullState.OPEN and not pull.draft:
            outstanding.update(key(actor) for actor in pull.requested_reviewers)
        for actor in pull.requested_reviewers:
            canonical.setdefault(key(actor), actor)
    actions = []

    def add(pull: Pull, reason: Reason, assignment=Assignment.NONE, *, account=None,
            team=None, actionable=False, reviews=()):
        if account is not None:
            actor_key = key(account)
            canonical.setdefault(actor_key, account)
            account = canonical[actor_key]
            if assignment is Assignment.PROPOSED_USER:
                proposed[actor_key] += 1
        eligibility = reviewer_eligibility(pull, account) if account is not None else None
        account_id = identities.get(account.casefold()) if account is not None else None
        actions.append(Action(pull.identity, reason, assignment, account=account,
                              account_id=account_id, team=team, actionable=actionable,
                              reviewer_eligibility=eligibility,
                              approval_ids=pull.approval_ids,
                              ambiguous_reviews=pull.ambiguous_reviews,
                              superseded_change_requests=pull.superseded_change_requests,
                              review_ids=tuple(r.review_id for r in reviews),
                              review_authors=tuple((r.actor_id, r.actor) for r in reviews),
                              current_head_submissions=pull.current_head_submissions))

    # Ownership routes are planned first so first-review balancing includes the
    # requests needed to return changed code to the reviewers who refused it.
    unassigned = []
    for pull in sorted(pulls, key=lambda p: (p.identity.created_at, p.identity.number)):
        first_action = len(actions)
        active = pull.state is PullState.OPEN and not pull.draft
        inactive_reason = Reason.CLOSED if pull.state is PullState.CLOSED else Reason.DRAFT
        requested = {key(actor) for actor in pull.requested_reviewers}
        crs = current_crs(pull)
        for actor in pull.requested_reviewers:
            own = tuple(r for r in crs if r.actor_id == key(actor))
            add(pull, Reason.EXISTING_REQUEST if active else inactive_reason,
                Assignment.EXISTING_USER, account=actor, actionable=active,
                reviews=own)
        for team in pull.requested_teams:
            add(pull, Reason.EXISTING_REQUEST if active else inactive_reason,
                Assignment.EXISTING_TEAM, team=team, actionable=active)
        if not active:
            if not requested and not pull.requested_teams:
                add(pull, inactive_reason)
            continue
        ambiguous_owners = {r.actor_id for r in pull.ambiguous_reviews}
        if pull.ambiguous_reviews:
            # Keep conflicting GitHub decisions visible without treating an
            # arbitrary order as approval or dispatching another request.
            add(pull, Reason.AMBIGUOUS_REVIEW, reviews=pull.ambiguous_reviews)
        # Only the latest formal decision on each account can be outstanding.
        cr_groups: dict[int, list[Review]] = {}
        for review in crs:
            cr_groups.setdefault(review.actor_id, []).append(review)
        for group in cr_groups.values():
            review = group[0]
            owner = review.actor_id
            if owner in requested or owner in ambiguous_owners:
                continue
            same_head = tuple(r for r in group if r.head == pull.identity.head)
            if same_head:
                add(pull, Reason.AWAITING_AUTHOR, account=pull.author,
                    reviews=tuple(group))
            elif review.head is not None and owner in pool_keys \
                    and reviewer_eligibility(pull, canonical[owner]) is ReviewerEligibility.ELIGIBLE:
                add(pull, Reason.CHANGED_HEAD_CR, Assignment.PROPOSED_USER,
                    account=canonical[owner], actionable=True, reviews=tuple(group))
            else:
                # The login in a review is historical. Without a current
                # verified roster mapping, report its ID but do not assign it.
                add(pull, Reason.AWAITING_OWNER, reviews=tuple(group))
        # A PR-author request or CR remains visible but cannot approve its own PR.
        conflicting = any(reviewer_eligibility(pull, actor) is ReviewerEligibility.PR_AUTHOR
                          for actor in pull.requested_reviewers)
        conflicting |= any(review.actor_id == pull.author_id for review in crs)
        independent_requested = any(reviewer_eligibility(pull, actor) is ReviewerEligibility.ELIGIBLE
                                    for actor in pull.requested_reviewers)
        unknown_requested = any(reviewer_eligibility(pull, actor) is ReviewerEligibility.UNKNOWN
                                for actor in pull.requested_reviewers)
        independent_proposed = any(a.assignment is Assignment.PROPOSED_USER
                                   and a.reviewer_eligibility is ReviewerEligibility.ELIGIBLE
                                   for a in actions[first_action:])
        if (conflicting and not pull.approval_ids and not pull.ambiguous_reviews
                and not pull.requested_teams
                and not independent_requested and not unknown_requested and not independent_proposed
                and not any(r.head == pull.identity.head for r in crs)):
            unassigned.append((pull, Reason.NON_AUTHOR_REVIEW))
            continue
        if pull.approval_ids and not crs:
            add(pull, Reason.APPROVED)
        if crs or requested or pull.requested_teams or pull.ambiguous_reviews or pull.approval_ids:
            continue
        unassigned.append((pull, Reason.REVIEW_NEEDED if pull.has_submitted_review else Reason.FIRST_REVIEW))
    for pull, reason in unassigned:
        eligible = [actor for actor in pool
                    if reviewer_eligibility(pull, actor) is ReviewerEligibility.ELIGIBLE]
        if not eligible:
            add(pull, Reason.NO_REVIEWER)
            continue
        actor = min(eligible, key=lambda a: (outstanding[key(a)] + proposed[key(a)],
                                             a.casefold()))
        add(pull, reason, Assignment.PROPOSED_USER, account=actor, actionable=True)
    rank = {reason: i for i, reason in enumerate(Reason)}
    # Changed-head CRs go back to their owners first. All other proposed
    # reviews share one oldest-first class, so new PRs cannot starve older
    # PRs whose earlier review no longer covers their current scope.
    ordinary_review = {Reason.FIRST_REVIEW, Reason.REVIEW_NEEDED, Reason.NON_AUTHOR_REVIEW}
    ordered = tuple(sorted(actions, key=lambda a: (
        rank[Reason.FIRST_REVIEW] if a.reason in ordinary_review else rank[a.reason],
        a.identity.created_at, a.identity.number, rank[a.reason], a.account or "", a.team or "")))
    loads = tuple(AccountLoad(canonical[actor_key], actor_key in pool_keys, outstanding[actor_key], proposed[actor_key],
                              tuple(a for a in ordered if a.account is not None
                                    and key(a.account) == actor_key))
                  for actor_key in sorted(canonical, key=lambda k: canonical[k].casefold()))
    return Worklist(ordered, loads)
