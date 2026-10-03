#!/usr/bin/env python3
"""Validate the immutable diff scope stamped by approve-guard."""
import argparse
import json
import re
import subprocess
import sys


def stack_scope(stack):
    return None if stack is None else {
        "number": stack["number"], "position": stack["position"],
        "base_ref": stack["base"]["ref"]}


def scope_matches(body, *, base_ref, base_sha, stack, head, merge_base):
    lines = [line.removeprefix("review-scope: ") for line in body.splitlines()
             if line.startswith("review-scope: ")]
    if len(lines) != 1:
        return False
    try:
        scope = json.loads(lines[0])
    except json.JSONDecodeError:
        return False
    if (not isinstance(scope, dict)
            or set(scope) != {"base_ref", "base_sha", "stack"}
            or scope["base_ref"] != base_ref or scope["stack"] != stack
            or not isinstance(scope["base_sha"], str)
            or re.fullmatch(r"[0-9a-f]{40}", scope["base_sha"]) is None):
        return False
    reviewed = scope["base_sha"]
    # No comparison request is needed for the exact recorded base.
    return reviewed == base_sha or merge_base(reviewed, head) == merge_base(base_sha, head)


def main():
    p = argparse.ArgumentParser()
    for name in ("repo", "head", "base-ref", "base-sha", "stack", "gh"):
        p.add_argument("--" + name, required=True)
    a = p.parse_args()
    review = json.load(sys.stdin)
    def merge_base(base, head):
        sha = subprocess.check_output([a.gh, "api",
            f"repos/{a.repo}/compare/{base}...{head}", "--jq", ".merge_base_commit.sha"],
            text=True).strip()
        if re.fullmatch(r"[0-9a-f]{40}", sha) is None:
            raise ValueError("GitHub comparison did not return a merge-base SHA")
        return sha
    matched = scope_matches(review.get("body", ""), base_ref=a.base_ref,
        base_sha=a.base_sha, stack=stack_scope(json.loads(a.stack)),
        head=a.head, merge_base=merge_base)
    return 0 if matched else 2


if __name__ == "__main__":
    sys.exit(main())
