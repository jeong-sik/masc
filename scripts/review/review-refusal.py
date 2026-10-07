#!/usr/bin/env python3
"""Explain why one APPROVED review is not admitted by approve-guard.

Diagnostic only: approve-guard decides admission with its own jq test and
review-scope.py. This helper never grants or widens anything; it re-runs the
same textual tests one at a time so a refusal can name the failing part and
print the footer a reviewer should have written.
"""
import argparse
import json
import re
import sys

TRUSTED = ("OWNER", "MEMBER", "COLLABORATOR")


def expected_footer(head, policy, base_sha, current_diff, release_run=""):
    parts = [f"approve-guard: head `{head}`", f"{policy} review"]
    if release_run:
        parts.append(f"release run {release_run}")
    parts.append(f"reviewed base `{base_sha}`")
    parts.append(f"diff sha256 `{current_diff}`")
    return " · ".join(parts)


def verdict_pattern(head, policy):
    if policy == "release":
        return re.compile(rf"^verdict: PASS head: {head} run: [1-9][0-9]* by: [A-Za-z0-9._-]+$")
    return re.compile(rf"^verdict: PASS head: {head} by: [A-Za-z0-9._-]+$")


def short(text, limit=160):
    text = text.replace("\n", "\\n")
    return text if len(text) <= limit else text[:limit] + "..."


def diagnose(review, *, head, policy, base_sha, current_diff, release_run=""):
    """Return a list of failed-test descriptions (empty when all textual tests pass)."""
    reasons = []
    body = review.get("body") or ""
    assoc = review.get("author_association") or "UNKNOWN"
    if assoc not in TRUSTED:
        reasons.append(
            f"author_association is {assoc}; approval needs OWNER, MEMBER or COLLABORATOR")
    lines = body.split("\n")
    first = lines[0].rstrip("\r") if lines else ""
    if not verdict_pattern(head, policy).fullmatch(first):
        want = (f"verdict: PASS head: {head} run: <run> by: <keeper>" if policy == "release"
                else f"verdict: PASS head: {head} by: <keeper>")
        reasons.append(f"first line is not the exact-head verdict; expected `{want}`, got `{short(first)}`")
    nonempty = [line for line in lines if line]
    last = nonempty[-1] if nonempty else ""
    prefix = f"approve-guard: head `{head}` · "
    tail_re = re.compile(rf" · reviewed base `[0-9a-f]{{40}}` · diff sha256 `{current_diff}`$")
    if not last.startswith(prefix):
        reasons.append(
            f"last non-empty line must start with `{prefix}` (backticked head, ' · ' separator); got `{short(last)}`")
    elif not tail_re.search(last):
        found = re.search(r"diff sha256 `([0-9a-f]{64})`", last)
        if "reviewed base" not in last and "diff sha256" not in last:
            reasons.append("footer lacks the ' · reviewed base `<40hex>` · diff sha256 `<64hex>`' tail")
        elif found and found.group(1) != current_diff:
            reasons.append(
                f"footer diff sha256 `{found.group(1)}` is not the current complete diff `{current_diff}`; the diff changed after the review")
        elif not re.search(r" · reviewed base `[0-9a-f]{40}` · ", last):
            reasons.append("footer reviewed base is missing or not a 40-hex commit")
        else:
            reasons.append("footer tail must end with ' · reviewed base `<40hex>` · diff sha256 `<current diff>`'")
    if reasons:
        reasons.append(
            "expected last line (copy): " + expected_footer(head, policy, base_sha, current_diff, release_run))
    return reasons


def main():
    p = argparse.ArgumentParser()
    for name in ("head", "policy", "base-sha", "current-diff"):
        p.add_argument("--" + name, required=True)
    p.add_argument("--release-run", default="")
    a = p.parse_args()
    review = json.load(sys.stdin)
    for line in diagnose(review, head=a.head, policy=a.policy, base_sha=a.base_sha,
                         current_diff=a.current_diff, release_run=a.release_run):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
