#!/usr/bin/env python3
"""Keep shared-account change requests until their signed owner replaces them.

Keeper names in review bodies are claims, not authenticated session identities.
Matching them catches conflicting claims; callers must still verify the session.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("review_decisions", HERE / "review-decisions.py")
decisions = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = decisions
spec.loader.exec_module(decisions)

FOOTER = re.compile(
    r"approve-guard: head `([0-9a-f]{40})` · (source|release) review"
    r"(?: · release run ([1-9][0-9]*))?"
    r" · replaces own CHANGES_REQUESTED ([1-9][0-9]*(?: [1-9][0-9]*)*)"
    r" · reviewed base `[0-9a-f]{40}` · diff sha256 `[0-9a-f]{64}`"
)


def actor_id(review):
    user = review.get("user")
    value = user.get("id") if isinstance(user, dict) else None
    return value if type(value) is int and value > 0 else None


def header(review, wanted):
    body = review.get("body")
    if not isinstance(body, str):
        return None
    first = body.split("\n", 1)[0]
    if wanted == "FAIL":
        first = first.removesuffix("\r")
    match = decisions.HEADER.fullmatch(first)
    return match if match and match[1] == wanted else None


def has_scope(lines):
    scopes = [line.removeprefix("review-scope: ") for line in lines
              if line.startswith("review-scope: ")]
    if len(scopes) != 1:
        return False
    try:
        scope = json.loads(scopes[0])
    except ValueError:
        return False
    if (not isinstance(scope, dict) or set(scope) != {"base_ref", "base_sha", "stack"}
            or not isinstance(scope["base_ref"], str) or not scope["base_ref"]
            or not isinstance(scope["base_sha"], str)
            or re.fullmatch(r"[0-9a-f]{40}", scope["base_sha"]) is None):
        return False
    stack = scope["stack"]
    return stack is None or (isinstance(stack, dict)
        and set(stack) == {"number", "position", "base_ref"}
        and type(stack["number"]) is int and stack["number"] > 0
        and type(stack["position"]) is int and stack["position"] > 0
        and isinstance(stack["base_ref"], str) and bool(stack["base_ref"]))


def outstanding(pages):
    """Return unresolved (review id, account id, claimed keeper) tuples."""
    if not isinstance(pages, list) or not pages or any(not isinstance(page, list) for page in pages):
        raise ValueError("expected complete review pages")
    records = [review for page in pages for review in page]
    ids = [review.get("id") for review in records if isinstance(review, dict)]
    if (len(ids) != len(records) or any(type(i) is not int or i < 1 for i in ids)
            or len(set(ids)) != len(ids)):
        raise ValueError("invalid or duplicate review id")
    pending = {}
    for review in sorted(records, key=lambda r: r["id"]):
        state = review.get("state")
        if state == "CHANGES_REQUESTED":
            match = header(review, "FAIL")
            pending[review["id"]] = (actor_id(review), match[4] if match else None)
        elif state == "APPROVED":
            match = header(review, "PASS")
            body = review.get("body")
            lines = body.split("\n") if isinstance(body, str) else []
            footer = FOOTER.fullmatch(next((line for line in reversed(lines) if line), ""))
            actor = actor_id(review)
            if (match is None or footer is None or footer[1] != match[2] or actor is None
                    or (footer[2] == "source" and (match[3] is not None or footer[3] is not None))
                    or (footer[2] == "release" and (match[3] is None or footer[3] != match[3]))
                    or not has_scope(lines)
                    or review.get("author_association") not in decisions.TRUSTED_ASSOCIATIONS):
                continue
            for value in footer[4].split():
                request_id = int(value)
                if pending.get(request_id) == (actor, match[4]):
                    del pending[request_id]
    return tuple((rid, *pending[rid]) for rid in sorted(pending))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--pr", required=True)
    parser.add_argument("--gh", default="gh")
    parser.add_argument("--mode", choices=("publish", "consume"), required=True)
    parser.add_argument("--reviewer-id", type=int)
    parser.add_argument("--keeper")
    parser.add_argument("--replace", type=int, action="append", default=[])
    args = parser.parse_args()
    try:
        path = f"repos/{args.repo}/pulls/{args.pr}/reviews?per_page=100"
        result = subprocess.run([args.gh, "api", "--paginate", "--slurp", path],
                                capture_output=True, text=True, check=True)
        pending = outstanding(json.loads(result.stdout))
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        print(f"approve-guard: change-request ownership unavailable: {error}", file=sys.stderr)
        return 1
    if args.mode == "consume":
        blocked = pending
    else:
        if args.reviewer_id is None:
            print("approve-guard: reviewer account identity unavailable", file=sys.stderr)
            return 2
        requested = set(args.replace)
        own = {rid: (actor, keeper) for rid, actor, keeper in pending
               if actor == args.reviewer_id}
        if (requested or own) and not args.keeper:
            print("approve-guard: replacement needs a signed review body", file=sys.stderr)
            return 2
        if any(rid not in own or own[rid][1] != args.keeper for rid in requested):
            print("approve-guard: replacement request signer is unknown or differs from this Keeper", file=sys.stderr)
            return 2
        blocked = tuple((rid, actor, keeper) for rid, actor, keeper in pending
                        if actor is None or (actor == args.reviewer_id and rid not in requested))
    if blocked:
        ids = ", ".join(str(item[0]) for item in blocked)
        print(f"approve-guard: unresolved change requests (review IDs {ids}); their owners must resolve them", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
