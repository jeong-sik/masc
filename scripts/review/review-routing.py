#!/usr/bin/env python3
"""Pure review routing from GitHub assignments and admitted source receipts.

The plan proposes requests, never claims reviews have started or completed.
All network reads and writes belong to the caller. Admission is supplied by the
existing source-receipt guard; a formal approval alone does not establish it.
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


formal_order = _load_review_helper("routing_formal_order", "review-formal-order.py")
cr_ownership = _load_review_helper("routing_cr_ownership", "review-cr-ownership.py")


class Reason(str, Enum):
    EXISTING_REQUEST = "existing_request"
    CHANGED_HEAD_CR = "changed_head_cr"
    AWAITING_AUTHOR = "awaiting_author"
    AWAITING_OWNER = "awaiting_owner"
    FIRST_REVIEW = "first_review"
    REVIEW_NEEDED = "review_needed"
    INDEPENDENT_REVIEW = "independent_review"
    COMMIT_IDENTITY_UNKNOWN = "commit_identity_unknown"
    ADMITTED = "admitted"
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
    COMMIT_ACTOR = "commit_actor"
    UNKNOWN = "unknown"


class BlockerState(str, Enum):
    FAIL = "FAIL"
    HOLD = "HOLD"
    COMMENT = "COMMENT"
    UNKNOWN = "UNKNOWN"
    INVALID = "INVALID"
    UNTRUSTED = "UNTRUSTED"


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
    head: str
    submitted_at: datetime


@dataclass(frozen=True)
class Blocker:
    actor: str | None
    record_id: int | None
    state: BlockerState
    raw_json: str


@dataclass(frozen=True)
class Pull:
    identity: Identity
    state: PullState
    draft: bool
    author: str
    author_id: int
    requested_reviewers: tuple[str, ...]
    requested_teams: tuple[str, ...]
    commit_accounts: tuple[str, ...]
    commit_actor_ids: tuple[int, ...]
    account_ids: tuple[tuple[str, int], ...]
    commit_identities_complete: bool
    reviews: tuple[Review, ...]
    unresolved_cr_ids: frozenset[int]
    admission: bool
    independent_source_review: bool
    blockers: tuple[Blocker, ...]


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
    independent_source_review: bool = False
    review_ids: tuple[int, ...] = ()
    blockers: tuple[Blocker, ...] = ()

    def to_json(self) -> dict:
        return {**self.identity.to_json(), "reason": self.reason.value,
                "assignment": self.assignment.value, "account": self.account,
                "account_id": self.account_id,
                "team": self.team, "actionable": self.actionable,
                "reviewer_eligibility": (self.reviewer_eligibility.value
                                         if self.reviewer_eligibility else None),
                "independent_source_review": self.independent_source_review,
                "review_ids": list(self.review_ids),
                "blockers": [json.loads(b.raw_json) for b in self.blockers]}


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
    if state is ReviewState.PENDING:
        return None
    user = raw.get("user")
    if not isinstance(user, dict):
        raise ValueError("review.user must be an API object")
    return Review(login(user.get("login"), "review.user.login"),
                  positive_id(user.get("id"), "review.user.id"),
                  positive_id(raw.get("id"), "review.id"), state,
                  sha(raw.get("commit_id"), "review.commit_id"),
                  instant(raw.get("submitted_at"), "review.submitted_at"))


def parse_blocker(raw: object) -> Blocker:
    if not isinstance(raw, dict):
        raise ValueError("blocker must be an object")
    if not {"actor", "id", "state"}.issubset(raw):
        raise ValueError("blocker requires actor, id and state")
    try:
        state = BlockerState(raw.get("state"))
    except (ValueError, TypeError) as exc:
        raise ValueError("unknown blocker state") from exc
    actor = raw.get("actor")
    if actor is not None:
        actor = login(actor, "blocker.actor")
    rid = raw.get("id")
    if rid is not None:
        rid = positive_id(rid, "blocker.id")
    return Blocker(actor, rid, state, frozen_json(raw, "blocker"))


def parse_pull(raw: object) -> Pull:
    if not isinstance(raw, dict):
        raise ValueError("pull must be an object")
    required = {"number", "title", "url", "state", "draft", "author", "head",
                "base_ref", "base_sha", "stack", "created_at", "requested_reviewers",
                "requested_teams", "author_id", "account_ids", "commit_accounts",
                "commit_actor_ids", "commit_identities_complete",
                "reviews", "admission", "independent_source_review", "blockers"}
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
    # Refuse an ambiguous latest formal decision just as the admission guard
    # does. Retain each CR separately until its own owner replaces it.
    formal_order.ordered_rows([r for r in review_records
                               if isinstance(r, dict) and r.get("state") in formal_order.FORMAL])
    unresolved = frozenset(rid for rid, _, _ in cr_ownership.outstanding([list(review_records)]))
    reviews = tuple(r for r in (parse_review(r) for r in review_records)
                    if r is not None)
    review_names = {}
    for review in reviews:
        name = review.actor.casefold()
        if review.actor_id in review_names and review_names[review.actor_id] != name:
            raise ValueError("one review account has conflicting logins")
        review_names[review.actor_id] = name
    if not isinstance(raw["account_ids"], dict):
        raise ValueError("account_ids must be an object")
    accounts = tuple((login(name, "account_ids").casefold(), positive_id(value, "account_ids"))
                     for name, value in raw["account_ids"].items())
    if len({name for name, _ in accounts}) != len(accounts):
        raise ValueError("duplicate account identity")
    author = login(raw["author"], "author")
    author_id = positive_id(raw["author_id"], "author_id")
    known = dict(accounts)
    if known.get(author.casefold()) != author_id or any(
            known.get(r.actor.casefold()) != r.actor_id for r in reviews):
        raise ValueError("account identity does not match author or review")
    commit_ids = tuple(positive_id(i, "commit_actor_ids")
                       for i in sequence(raw["commit_actor_ids"], "commit_actor_ids"))
    commit_names = unique_logins(raw["commit_accounts"], "commit_accounts")
    if (len(commit_names) != len(commit_ids)
            or any(known.get(name.casefold()) != actor_id
                   for name, actor_id in zip(commit_names, commit_ids))):
        raise ValueError("commit account identity mismatch")
    return Pull(identity, state, boolean(raw["draft"], "draft"), author, author_id,
                unique_logins(raw["requested_reviewers"], "requested_reviewers"),
                unique_logins(raw["requested_teams"], "requested_teams"),
                commit_names, commit_ids, accounts,
                boolean(raw["commit_identities_complete"], "commit_identities_complete"), reviews, unresolved,
                boolean(raw["admission"], "admission"),
                boolean(raw["independent_source_review"], "independent_source_review"),
                tuple(parse_blocker(b) for b in sequence(raw["blockers"], "blockers")))


def reviewer_eligibility(pull: Pull, account: str) -> ReviewerEligibility:
    key = account.casefold()
    actor_id = dict(pull.account_ids).get(key)
    if actor_id is None:
        return ReviewerEligibility.UNKNOWN
    if actor_id == pull.author_id:
        return ReviewerEligibility.PR_AUTHOR
    if actor_id in pull.commit_actor_ids:
        return ReviewerEligibility.COMMIT_ACTOR
    if not pull.commit_identities_complete:
        return ReviewerEligibility.UNKNOWN
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
            team=None, actionable=False, reviews=(), blockers=()):
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
                              independent_source_review=pull.independent_source_review,
                              review_ids=tuple(r.review_id for r in reviews), blockers=tuple(blockers)))

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
            own = tuple(r for r in crs if key(r.actor) == key(actor))
            owned = tuple(b for b in pull.blockers if b.actor is not None
                          and key(b.actor) == key(actor))
            add(pull, Reason.EXISTING_REQUEST if active else inactive_reason,
                Assignment.EXISTING_USER, account=actor, actionable=active,
                reviews=own, blockers=owned)
        for team in pull.requested_teams:
            add(pull, Reason.EXISTING_REQUEST if active else inactive_reason,
                Assignment.EXISTING_TEAM, team=team, actionable=active)
        if not active:
            if not requested and not pull.requested_teams:
                add(pull, inactive_reason)
            continue
        # Exact-head structured refusals cannot be inferred resolved by a code
        # change, formal approval, comment, or a different account's review.
        blocker_groups: dict[int | str | None, list[Blocker]] = {}
        for blocker in pull.blockers:
            owner = key(blocker.actor) if blocker.actor is not None else None
            blocker_groups.setdefault(owner, []).append(blocker)
        for owner, blockers in blocker_groups.items():
            if owner not in requested:
                own = tuple(r for r in crs if key(r.actor) == owner)
                same_head_ids = {r.review_id for r in own if r.head == pull.identity.head}
                independent = tuple(b for b in blockers
                                    if not (b.record_id in same_head_ids
                                            and json.loads(b.raw_json).get("kind") == "review"))
                if independent:
                    add(pull, Reason.AWAITING_OWNER, account=blockers[0].actor,
                        reviews=own, blockers=independent)
        # A shared account may have several unresolved CRs. Keep every ID,
        # but propose at most one request to that account.
        cr_groups: dict[int, list[Review]] = {}
        for review in crs:
            cr_groups.setdefault(review.actor_id, []).append(review)
        for group in cr_groups.values():
            review = group[0]
            owner = key(review.actor)
            if owner in requested:
                continue
            same_head = tuple(r for r in group if r.head == pull.identity.head)
            if same_head:
                same_head_ids = {r.review_id for r in same_head}
                own_blockers = tuple(b for b in blocker_groups.get(owner, ())
                                     if b.record_id in same_head_ids
                                     and json.loads(b.raw_json).get("kind") == "review")
                add(pull, Reason.AWAITING_AUTHOR, account=pull.author,
                    reviews=tuple(group), blockers=own_blockers)
            elif owner in blocker_groups:
                continue
            elif not pull.admission and owner in pool_keys \
                    and reviewer_eligibility(pull, review.actor) is ReviewerEligibility.ELIGIBLE:
                add(pull, Reason.CHANGED_HEAD_CR, Assignment.PROPOSED_USER,
                    account=review.actor, actionable=True, reviews=tuple(group))
            else:
                add(pull, Reason.AWAITING_OWNER, account=review.actor, reviews=tuple(group))
        # An existing request or CR stays owned even when that account also
        # contributed to the current diff. It does not supply an independent
        # reviewer, so propose one separately while retaining all old facts.
        conflicting = any(reviewer_eligibility(pull, actor) in
                          (ReviewerEligibility.PR_AUTHOR, ReviewerEligibility.COMMIT_ACTOR)
                          for actor in pull.requested_reviewers)
        conflicting |= any(reviewer_eligibility(pull, review.actor) in
                           (ReviewerEligibility.PR_AUTHOR, ReviewerEligibility.COMMIT_ACTOR)
                           for review in crs)
        independent_requested = any(reviewer_eligibility(pull, actor) is ReviewerEligibility.ELIGIBLE
                                    for actor in pull.requested_reviewers)
        unknown_requested = any(reviewer_eligibility(pull, actor) is ReviewerEligibility.UNKNOWN
                                for actor in pull.requested_reviewers)
        independent_proposed = any(a.assignment is Assignment.PROPOSED_USER
                                   and a.reviewer_eligibility is ReviewerEligibility.ELIGIBLE
                                   for a in actions[first_action:])
        if (conflicting and not pull.admission and not pull.independent_source_review
                and not pull.requested_teams
                and not independent_requested and not unknown_requested and not independent_proposed
                and not any(r.head == pull.identity.head for r in crs)):
            unassigned.append((pull, Reason.INDEPENDENT_REVIEW))
            continue
        if crs or pull.blockers or requested or pull.requested_teams:
            continue
        if pull.admission:
            add(pull, Reason.ADMITTED)
        else:
            unassigned.append((pull, Reason.REVIEW_NEEDED if pull.reviews else Reason.FIRST_REVIEW))
    for pull, reason in unassigned:
        if not pull.commit_identities_complete:
            add(pull, Reason.COMMIT_IDENTITY_UNKNOWN)
            continue
        eligible = [actor for actor in pool
                    if reviewer_eligibility(pull, actor) is ReviewerEligibility.ELIGIBLE]
        if not eligible:
            add(pull, Reason.NO_REVIEWER)
            continue
        actor = min(eligible, key=lambda a: (outstanding[key(a)] + proposed[key(a)],
                                             a.casefold()))
        add(pull, reason, Assignment.PROPOSED_USER, account=actor, actionable=True)
    rank = {reason: i for i, reason in enumerate(Reason)}
    ordered = tuple(sorted(actions, key=lambda a: (rank[a.reason], a.identity.created_at,
                                                  a.identity.number, a.account or "", a.team or "")))
    loads = tuple(AccountLoad(canonical[actor_key], actor_key in pool_keys, outstanding[actor_key], proposed[actor_key],
                              tuple(a for a in ordered if a.account is not None
                                    and key(a.account) == actor_key))
                  for actor_key in sorted(canonical, key=lambda k: canonical[k].casefold()))
    return Worklist(ordered, loads)
