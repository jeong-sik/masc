#!/usr/bin/env python3
"""Reduce exact-head review decisions by the authenticated GitHub author.

The core consumes API records, not claimed Keeper names. A later PASS can
supersede only that account's decisions; an approval is still admitted separately
by review-refusal.py. This module reads no network or repository state.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
from enum import Enum
import json
import re
import sys
from typing import Iterable


class State(str, Enum):
    PASS = "PASS"
    FAIL = "FAIL"
    HOLD = "HOLD"
    COMMENT = "COMMENT"
    UNKNOWN = "UNKNOWN"
    INVALID = "INVALID"
    UNTRUSTED = "UNTRUSTED"


class Kind(str, Enum):
    COMMENT = "comment"
    REVIEW = "review"


class ReviewState(str, Enum):
    COMMENTED = "COMMENTED"
    APPROVED = "APPROVED"
    CHANGES_REQUESTED = "CHANGES_REQUESTED"
    DISMISSED = "DISMISSED"
    PENDING = "PENDING"


TRUSTED_ASSOCIATIONS = frozenset(("OWNER", "MEMBER", "COLLABORATOR"))
HEADER = re.compile(
    r"verdict: (PASS|FAIL) head: ([0-9a-f]{40})"
    r"(?: run: ([1-9][0-9]*))? by: ([A-Za-z0-9._-]+)"
)
SHA = re.compile(r"[0-9a-f]{40}")


@dataclass(frozen=True)
class Decision:
    kind: Kind
    record_id: int | None
    actor: str | None
    state: State
    run: str
    by: str
    created_at: datetime
    decision_at: datetime
    url: str | None
    ordinal: int

    @property
    def blocks(self) -> bool:
        return self.state is not State.PASS

    @property
    def actor_key(self) -> tuple:
        # Unidentified records cannot assert a shared author and withdraw one
        # another's decisions. The ordinal also keeps missing API IDs distinct.
        if self.actor is not None:
            return ("actor", self.actor)
        return ("unidentified", self.kind.value, self.record_id, self.ordinal)

    @property
    def order(self) -> tuple:
        # Two contradictory decisions at one API timestamp cannot grant PASS.
        return (self.decision_at, self.blocks, self.state.value,
                self.kind.value, self.record_id or 0, self.ordinal)

    def to_json(self) -> dict:
        return {
            "actor": self.actor,
            "id": self.record_id,
            "kind": self.kind.value,
            "state": self.state.value,
            "run": self.run,
            "by": self.by,
            "created_at": self.created_at.isoformat(),
            "decision_at": self.decision_at.isoformat(),
            "url": self.url,
        }


@dataclass(frozen=True)
class Reduction:
    decisions: tuple[Decision, ...]
    selected: Decision | None

    @property
    def blockers(self) -> tuple[Decision, ...]:
        return tuple(d for d in self.decisions if d.blocks)

    def verdict(self) -> str:
        if self.selected is None:
            return ""
        d = self.selected
        return f"{d.state.value} {d.run} {d.by}"

    def to_json(self) -> dict:
        d = self.selected
        return {
            "state": d.state.value if d else None,
            "run": d.run if d else None,
            "by": d.by if d else None,
            "blockers": [b.to_json() for b in self.blockers],
            "decisions": [item.to_json() for item in self.decisions],
        }


def timestamp(value: object, field: str) -> datetime:
    if not isinstance(value, str):
        raise ValueError(f"structured verdict lacks {field}")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError(f"structured verdict has invalid {field}") from exc
    if parsed.tzinfo is None:
        raise ValueError(f"structured verdict {field} must include a timezone")
    return parsed.astimezone(timezone.utc)


def actor_login(record: dict) -> str | None:
    user = record.get("user")
    login = user.get("login") if isinstance(user, dict) else None
    if isinstance(login, str) and login and not any(c.isspace() for c in login):
        return login
    return None


def parse_record(envelope: dict, *, head: str, ordinal: int,
                 exclude_reviews: frozenset[int] = frozenset()) -> Decision | None:
    if not isinstance(envelope, dict):
        raise ValueError("decision envelope must be an object")
    try:
        kind = Kind(envelope.get("kind"))
    except ValueError as exc:
        raise ValueError("decision envelope has unknown kind") from exc
    record = envelope.get("record")
    if not isinstance(record, dict):
        raise ValueError("decision envelope record must be an object")
    record_id = record.get("id")
    if type(record_id) is not int or record_id < 1:
        record_id = None
    review_state = None
    if kind is Kind.REVIEW:
        try:
            review_state = ReviewState(record.get("state"))
        except ValueError:
            pass
        # Draft reviews have not issued a decision. Neither their positive nor
        # negative contents may change the published decision state.
        if review_state in (ReviewState.DISMISSED, ReviewState.PENDING):
            return None
        if review_state is ReviewState.CHANGES_REQUESTED and record_id in exclude_reviews:
            return None
    body = record.get("body")
    if not isinstance(body, str) or not body:
        return None
    first_line = body.split("\n", 1)[0].removesuffix("\r")
    words = first_line.split()
    if not words or words[0] != "verdict:":
        return None
    head_fields = [words[i + 1] for i, word in enumerate(words[:-1])
                   if word == "head:"]
    if head not in head_fields:
        return None
    state_name = words[1] if len(words) > 1 else ""
    state = State.__members__.get(state_name, State.UNKNOWN)
    run = by = "-"
    if state in (State.PASS, State.FAIL):
        header = HEADER.fullmatch(first_line)
        if header is None or len(head_fields) != 1 or header[2] != head:
            state = State.INVALID
        else:
            run = header[3] or "-"
            by = header[4]
    elif state not in (State.HOLD, State.COMMENT):
        state = State.UNKNOWN
    if kind is Kind.REVIEW and review_state is None:
        # An unrecognized publication state cannot grant positive authority.
        state = State.UNKNOWN
    elif review_state is ReviewState.CHANGES_REQUESTED and state is State.PASS:
        # The published API decision is a refusal. A contradictory first-line
        # PASS cannot authorize approval or withdraw this actor's older refusal.
        state = State.INVALID
    actor = actor_login(record)
    if state is State.PASS and (
        record.get("author_association") not in TRUSTED_ASSOCIATIONS
        or actor is None
    ):
        state = State.UNTRUSTED
    created_field = "created_at" if kind is Kind.COMMENT else "submitted_at"
    created = timestamp(record.get(created_field), created_field)
    decision_at = created
    # The creation time of a positive decision is immutable authority. Editing
    # its explanation must not move it beyond a subsequently posted refusal.
    if kind is Kind.COMMENT and state is not State.PASS:
        updated = timestamp(record.get("updated_at", record.get("created_at")), "updated_at")
        decision_at = max(created, updated)
    return Decision(kind, record_id, actor, state, run, by, created, decision_at,
                    record.get("html_url") if isinstance(record.get("html_url"), str) else None,
                    ordinal)


def reduce_decisions(envelopes: Iterable[dict], *, head: str,
                     actor: str | None = None,
                     exclude_reviews: frozenset[int] = frozenset()) -> Reduction:
    if SHA.fullmatch(head) is None:
        raise ValueError("head must be one lowercase 40-character SHA")
    latest: dict[tuple, Decision] = {}
    for ordinal, envelope in enumerate(envelopes):
        decision = parse_record(envelope, head=head, ordinal=ordinal,
                                exclude_reviews=exclude_reviews)
        if decision is None:
            continue
        if actor is not None and decision.actor is not None and decision.actor != actor:
            continue
        previous = latest.get(decision.actor_key)
        if previous is None or decision.order > previous.order:
            latest[decision.actor_key] = decision
    decisions = tuple(sorted(latest.values(), key=lambda d: d.order, reverse=True))
    blockers = tuple(d for d in decisions if d.blocks)
    # A positive record cannot withdraw a different authenticated author's
    # refusal. The chosen blocker is diagnostic; every blocker is retained.
    selected = (blockers or decisions or (None,))[0]
    return Reduction(decisions, selected)


def positive_id(value: str) -> int:
    if not value.isascii() or not value.isdecimal() or int(value) < 1:
        raise argparse.ArgumentTypeError("review ID must be a positive integer")
    return int(value)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--head", required=True)
    parser.add_argument("--actor")
    parser.add_argument("--exclude-review", action="append", type=positive_id, default=[])
    parser.add_argument("--format", choices=("verdict", "json"), default="verdict")
    args = parser.parse_args()
    try:
        records = [json.loads(line) for line in sys.stdin if line.strip()]
        reduced = reduce_decisions(records, head=args.head, actor=args.actor,
                                   exclude_reviews=frozenset(args.exclude_review))
    except (ValueError, TypeError) as exc:
        print(f"review-decisions: {exc}", file=sys.stderr)
        return 1
    if args.format == "json":
        print(json.dumps(reduced.to_json(), separators=(",", ":")))
    else:
        print(reduced.verdict())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
