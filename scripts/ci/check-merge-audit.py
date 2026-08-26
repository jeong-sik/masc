#!/usr/bin/env python3
"""Audit a merged main commit's required-check conclusions.

Broken window this closes (PR #30463, 2026-08-25 07:21:50Z): a PR merged with
``Dashboard``=CANCELLED, ``Build and Test``=SKIPPED and ``CI Gate``=CANCELLED.
Branch protection only requires a context to *report*; a CANCELLED or SKIPPED
conclusion satisfies "strict" contexts on GitHub when an admin merges, and
nothing in-repo looked at the conclusions a merge actually landed with.

This script is the in-repo half: for the merge commit it names, it fetches the
commit's combined status plus check-run conclusions, and fails when a required
check's final conclusion on the merged SHA is anything other than ``success``.
A check that never finished -- CANCELLED -- or never ran -- SKIPPED -- is
exactly the "unfinished verdict" the merge gate must not treat as a pass.

Exit 0  -- every required check concluded ``success`` on the merged SHA.
Exit 1  -- at least one required check concluded CANCELLED/SKIPPED/failure.
Exit 2  -- the audit could not run (bad arguments, API unavailable).

The GitHub-facing half lives in .github/workflows/main-ci-verdict.yml, whose
``merge-audit`` job calls this on every push to main and promotes a non-clean
merge to a tracking issue immediately, instead of waiting for the 30-minute
timer that only speaks for scheduled runs.

Usage (from a GitHub Actions step with GH_TOKEN and GITHUB_REPOSITORY set):

    python3 scripts/ci/check-merge-audit.py --sha <merged-sha> \\
        [--contexts "CI Gate"] [--json-out path]

Locally, without a token, ``--status-file``/``--check-runs-file`` replay
fixtures captured by ``gh api`` so the decision function is testable offline.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request
from typing import Any

REQUIRED_CONTEXTS_DEFAULT = "CI Gate"
EXIT_CLEAN = 0
EXIT_UNCLEAN_MERGE = 1
EXIT_CANNOT_AUDIT = 2

# Conclusions that mean the check produced a verdict.
VERDICT_CONCLUSIONS = {"success", "failure"}


def parse_contexts(raw: str) -> list[str]:
    """Split a CSV of required contexts, dropping empties and whitespace."""
    return [c.strip() for c in raw.split(",") if c.strip()]


def load_check_runs(payload: Any) -> list[dict[str, Any]]:
    """Accept either the raw check-runs response or the bare list.

    ``gh api .../check-runs > fixture.json`` captures the envelope
    (``total_count`` + ``check_runs``); a jq-processed capture is the bare
    list. Both are valid fixtures, so both are unwrapped here.
    """
    if isinstance(payload, dict):
        return list(payload.get("check_runs") or [])
    return list(payload or [])


def load_json(path: str) -> Any:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def fetch_json(url: str, token: str) -> Any:
    """GET a GitHub API endpoint and decode JSON. Raises on HTTP failure."""
    request = urllib.request.Request(url)
    request.add_header("Accept", "application/vnd.github+json")
    request.add_header("Authorization", f"Bearer {token}")
    request.add_header("X-GitHub-Api-Version", "2022-11-28")
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def combined_status_to_conclusions(
    combined_status: dict[str, Any],
) -> dict[str, str]:
    """Map ``combined status`` contexts to their state (legacy statuses API).

    The statuses API reports ``state`` (success/failure/pending/error) rather
    than check-run ``conclusion``. A pending state means no verdict yet, which
    for this audit is the same as CANCELLED: the merge landed before the check
    could speak.
    """
    contexts: dict[str, str] = {}
    for entry in combined_status.get("statuses") or []:
        context = entry.get("context")
        state = entry.get("state")
        if context and state:
            contexts[context] = state
    return contexts


def check_runs_to_conclusions(check_runs: list[dict[str, Any]]) -> dict[str, str]:
    """Map check runs to the conclusion of their *latest* run per name.

    Several runs of the same check name can exist on one SHA (re-runs). The
    merge landed with the newest one, so the newest conclusion wins: the list
    is ordered newest-first by the API.
    """
    conclusions: dict[str, str] = {}
    for run in check_runs or []:
        name = run.get("name")
        status = run.get("status")
        conclusion = run.get("conclusion")
        if not name:
            continue
        if name in conclusions:
            continue  # only the newest run per name decides
        if status != "completed":
            conclusions[name] = "in_progress"
        else:
            conclusions[name] = conclusion or "none"
    return conclusions


def classify_conclusion(conclusion: str) -> tuple[str, str]:
    """Return (bucket, human explanation) for one check conclusion.

    Buckets: ``pass``, ``fail``, ``unfinished``. CANCELLED and SKIPPED are
    unfinished: the check never produced a verdict, so the merge carried no
    evidence for that required context. That is the exact shape PR #30463
    slipped through with, and what this audit refuses to bless.
    """
    if conclusion == "success":
        return ("pass", "concluded success")
    if conclusion in ("cancelled", "skipped", "in_progress", "pending", "none", ""):
        return (
            "unfinished",
            f"no verdict: {conclusion or 'none'} — the merge landed before this check could speak",
        )
    return ("fail", f"concluded {conclusion}")


def audit_merge(
    required: list[str],
    status_conclusions: dict[str, str],
    check_run_conclusions: dict[str, str],
) -> tuple[bool, list[str], list[dict[str, str]]]:
    """Decide whether a merge is clean; return (clean, summary, offending).

    Check-run conclusions win over legacy status states when both exist for a
    context, because the CI workflow reports through check runs and the
    statuses layer can lag behind it.
    """
    offending: list[dict[str, str]] = []
    lines: list[str] = []

    for context in required:
        conclusion = check_run_conclusions.get(
            context, status_conclusions.get(context)
        )
        if conclusion is None:
            # A required context with no run at all on the merged SHA is the
            # loudest form of unfinished: branch protection saw *some* run on
            # the PR head, but the merge commit never got one.
            offending.append(
                {
                    "context": context,
                    "conclusion": "absent",
                    "bucket": "unfinished",
                    "explanation": "no check run or status for this context on the merged SHA",
                }
            )
            lines.append(f"UNFINISHED {context}: no run on the merged SHA")
            continue
        bucket, explanation = classify_conclusion(conclusion)
        if bucket == "pass":
            lines.append(f"PASS {context}: {explanation}")
        else:
            offending.append(
                {
                    "context": context,
                    "conclusion": conclusion,
                    "bucket": bucket,
                    "explanation": explanation,
                }
            )
            marker = "UNFINISHED" if bucket == "unfinished" else "FAIL"
            lines.append(f"{marker} {context}: {explanation}")

    return (not offending, lines, offending)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--sha", required=True, help="merged commit SHA to audit")
    parser.add_argument(
        "--contexts",
        default=REQUIRED_CONTEXTS_DEFAULT,
        help=f"CSV of required contexts (default: {REQUIRED_CONTEXTS_DEFAULT!r})",
    )
    parser.add_argument(
        "--json-out",
        help="write the audit result (clean flag, offending checks) as JSON here",
    )
    parser.add_argument(
        "--status-file",
        help="replay a captured ``combined status`` JSON fixture instead of the API",
    )
    parser.add_argument(
        "--check-runs-file",
        help="replay a captured check-runs JSON fixture instead of the API",
    )
    parser.add_argument(
        "--repo",
        help="repository in owner/name form (default: GITHUB_REPOSITORY)",
    )
    args = parser.parse_args(argv)

    required = parse_contexts(args.contexts)
    if not required:
        print("::error title=merge audit misconfigured::no required contexts given")
        return EXIT_CANNOT_AUDIT

    repo = args.repo or os.environ.get("GITHUB_REPOSITORY", "")
    if not repo:
        print("::error title=merge audit misconfigured::--repo or GITHUB_REPOSITORY required")
        return EXIT_CANNOT_AUDIT

    sha = args.sha.strip()
    if not sha:
        print("::error title=merge audit misconfigured::--sha is empty")
        return EXIT_CANNOT_AUDIT

    try:
        if args.status_file:
            combined_status = load_json(args.status_file)
        else:
            token = os.environ.get("GH_TOKEN", "")
            if not token:
                print(
                    "::error title=merge audit unavailable::GH_TOKEN is required "
                    "when --status-file is not given"
                )
                return EXIT_CANNOT_AUDIT
            combined_status = fetch_json(
                f"https://api.github.com/repos/{repo}/commits/{sha}/status", token
            )
        if args.check_runs_file:
            check_runs = load_check_runs(load_json(args.check_runs_file))
        else:
            token = os.environ.get("GH_TOKEN", "")
            if not token:
                print(
                    "::error title=merge audit unavailable::GH_TOKEN is required "
                    "when --check-runs-file is not given"
                )
                return EXIT_CANNOT_AUDIT
            check_runs = fetch_json(
                f"https://api.github.com/repos/{repo}/commits/{sha}/check-runs",
                token,
            ).get("check_runs", [])
    except (OSError, ValueError) as error:
        print(f"::error title=merge audit unavailable::{error}")
        return EXIT_CANNOT_AUDIT

    clean, lines, offending = audit_merge(
        required,
        combined_status_to_conclusions(combined_status),
        check_runs_to_conclusions(check_runs),
    )

    print(f"merge audit for {repo}@{sha[:10]} required={required}")
    for line in lines:
        print(f"  {line}")

    if args.json_out:
        payload = {
            "repo": repo,
            "sha": sha,
            "required": required,
            "clean": clean,
            "offending": offending,
        }
        with open(args.json_out, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")

    if clean:
        print("merge audit: CLEAN — every required check concluded success")
        return EXIT_CLEAN

    print(
        "::error title=merged with unfinished verdicts::"
        "a required check carried no success conclusion onto main; "
        "see the lines above"
    )
    return EXIT_UNCLEAN_MERGE


if __name__ == "__main__":
    sys.exit(main())
