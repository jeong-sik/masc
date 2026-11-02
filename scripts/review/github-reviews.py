#!/usr/bin/env python3
"""Evaluate GitHub's submitted reviews without requiring a review-body format.

The evidence here is the GitHub account and review commit_id. It cannot show
which Keeper session wrote a review, or which base and complete diff it saw.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import re
import subprocess
import sys


SHA = re.compile(r"[0-9a-f]{40}")
REPO = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
STATES = frozenset(("APPROVED", "CHANGES_REQUESTED", "DISMISSED", "COMMENTED", "PENDING"))
FORMAL = frozenset(("APPROVED", "CHANGES_REQUESTED", "DISMISSED"))


class Refused(ValueError):
    """The requested head is no longer the PR's current head."""


class ArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError(message)


def sha(value, label):
    if not isinstance(value, str) or SHA.fullmatch(value) is None:
        raise ValueError(f"invalid {label}")
    return value


def positive_id(value, label):
    if type(value) is not int or value < 1:
        raise ValueError(f"invalid {label}")
    return value


def submitted_at(value):
    if not isinstance(value, str):
        raise ValueError("formal review lacks submitted_at")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError("formal review has invalid submitted_at") from exc
    if parsed.tzinfo is None:
        raise ValueError("formal review submitted_at must include a timezone")
    return parsed.astimezone(timezone.utc)


def actor_login(review):
    user = review.get("user")
    login = user.get("login") if isinstance(user, dict) else None
    if isinstance(login, str) and login and not any(c.isspace() for c in login):
        return login
    return None


def pr_identity(pr):
    if not isinstance(pr, dict):
        raise ValueError("PR must be an object")
    number = positive_id(pr.get("number"), "PR number")
    user = pr.get("user")
    pr_head = pr.get("head")
    if not isinstance(user, dict) or not isinstance(pr_head, dict):
        raise ValueError("PR author or head missing")
    return (number, positive_id(user.get("id"), "PR author account ID"),
            sha(pr_head.get("sha"), "PR head"))


def evaluate(pr, reviews, *, head):
    """Return current review IDs and change requests for one PR snapshot.

    A dismissed review is a final, non-approval state for its author. A comment
    or pending draft does not replace a submitted formal decision. The same
    account's latest formal decision is determined by submission time, not ID.
    A current non-author approval is returned regardless of review-body format
    or account association. Earlier requests replaced by an account's later
    approval are returned separately; that does not establish their resolution.
    Equally timed decisions with different states or target commits are reported
    in ambiguous_review_ids; possible change requests remain visible. Raise
    ValueError for malformed input and Refused for a changed PR head. Approval
    IDs refer to review records, not to account IDs.
    """
    head = sha(head, "expected head")
    number, author_id, current_head = pr_identity(pr)
    if current_head != head:
        raise Refused("PR head changed")
    if not isinstance(reviews, list):
        raise ValueError("reviews must be an array")

    latest = {}
    latest_approval = {}
    request_history = {}
    seen = set()
    for review in reviews:
        if (not isinstance(review, dict) or not isinstance(review.get("state"), str)
                or review["state"] not in STATES):
            raise ValueError("invalid review record or state")
        rid = positive_id(review.get("id"), "review ID")
        if rid in seen:
            raise ValueError("duplicate review ID in paginated history")
        seen.add(rid)
        if review["state"] not in FORMAL:
            continue
        user = review.get("user")
        if not isinstance(user, dict):
            raise ValueError("formal review account missing")
        account_id = positive_id(user.get("id"), "reviewer account ID")
        if actor_login(review) is None:
            raise ValueError("formal review account login missing")
        if review["state"] == "APPROVED":
            sha(review.get("commit_id"), "approval commit_id")
        when = submitted_at(review.get("submitted_at"))
        if review["state"] == "CHANGES_REQUESTED":
            request_history.setdefault(account_id, []).append((when, review))
        elif review["state"] == "APPROVED":
            if account_id not in latest_approval or when > latest_approval[account_id]:
                latest_approval[account_id] = when
        previous = latest.get(account_id)
        if previous is None or when > previous[0]:
            latest[account_id] = (when, [review])
        elif when == previous[0]:
            previous[1].append(review)

    approvals = []
    requests = []
    superseded = []
    ambiguous = []
    for _, matching in latest.values():
        review = matching[0]
        def outcome(record):
            state = record["state"]
            commit = record.get("commit_id") if state in ("APPROVED", "CHANGES_REQUESTED") else None
            return state, commit

        if any(outcome(record) != outcome(review) for record in matching[1:]):
            ambiguous.extend(record["id"] for record in matching)
            requests.extend({"id": record["id"], "login": record["user"]["login"]}
                            for record in matching if record["state"] == "CHANGES_REQUESTED")
        elif review["state"] == "APPROVED":
            if review["user"]["id"] != author_id and review["commit_id"] == head:
                approvals.extend(record["id"] for record in matching)
        elif review["state"] == "CHANGES_REQUESTED":
            requests.extend({"id": record["id"], "login": record["user"]["login"]}
                            for record in matching)
    for account_id, history in request_history.items():
        approved_at = latest_approval.get(account_id)
        if approved_at is None:
            continue
        for when, request in history:
            if when < approved_at:
                superseded.append({"id": request["id"], "login": request["user"]["login"]})
    return {"pr": number, "head": head, "approval_ids": sorted(approvals),
            "change_requests": sorted(requests, key=lambda item: item["id"]),
            "superseded_change_requests": sorted(superseded, key=lambda item: item["id"]),
            "ambiguous_review_ids": sorted(ambiguous),
            "provenance": "github_review_commit_id"}


def gh_json(gh, *args):
    try:
        result = subprocess.run([gh, "api", *args], capture_output=True, text=True, check=False)
    except (OSError, UnicodeError) as exc:
        raise ValueError(f"cannot execute gh: {exc}") from exc
    if result.returncode != 0:
        raise ValueError(f"gh api failed: {result.stderr.strip() or result.returncode}")
    try:
        return json.loads(result.stdout)
    except (ValueError, UnicodeError) as exc:
        raise ValueError("gh api returned invalid JSON") from exc


def main(argv=None):
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--pr", type=int, required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--gh", default="gh")
    try:
        args = parser.parse_args(argv)
        if REPO.fullmatch(args.repo) is None:
            raise ValueError("invalid repository")
        positive_id(args.pr, "PR number")
        sha(args.head, "expected head")
        endpoint = f"repos/{args.repo}/pulls/{args.pr}"
        before = gh_json(args.gh, endpoint)
        if pr_identity(before)[0] != args.pr:
            raise ValueError("PR number does not match the requested PR")
        pages = gh_json(args.gh, "--paginate", "--slurp", f"{endpoint}/reviews")
        if not isinstance(pages, list) or not all(isinstance(page, list) for page in pages):
            raise ValueError("paginated reviews must be an array of arrays")
        after = gh_json(args.gh, endpoint)
        if pr_identity(before) != pr_identity(after):
            raise Refused("PR identity or head changed during review read")
        result = evaluate(after, [review for page in pages for review in page], head=args.head)
    except Refused as exc:
        print(f"github-reviews: {exc}", file=sys.stderr)
        return 2
    except (ValueError, TypeError) as exc:
        print(f"github-reviews: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["approval_ids"] and not result["change_requests"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
