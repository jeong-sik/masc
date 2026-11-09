"""The nightly verdict a release cut sits on, printed at cut time.

A cut used to proceed over a red nightly because the chronic red thread
(#42430) made every new failure read like yesterday's: the release lane
never looked at the nightly at all. This gate reads the newest scheduled
nightly Test run on main that is an ancestor of the cut head, prints its
verdict and its failing jobs, and refuses the cut unless that verdict is
green or its run id and head sha are recorded in
scripts/ci/nightly_baseline.json. The refusal is not a gate that blocks
forever: a release owner decides to ride a red nightly by recording the
run, which turns an implicit pass into a recorded decision.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

BASELINE = Path(__file__).resolve().parents[2] / "scripts/ci/nightly_baseline.json"
RUN_PAGE = "actions/workflows/test.yml/runs"


class GateError(Exception):
    """A refused cut: the message names the decision a release owner owes."""


def gh_api(repo: str, path: str) -> str:
    result = subprocess.run(
        ["gh", "api", path],
        env={**os.environ, "GH_REPO": repo},
        text=True, capture_output=True, timeout=120,
    )
    if result.returncode != 0:
        raise GateError(
            f"gh api {path} failed: "
            f"{result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def ancestor_nightly(repo: str, cut_sha: str) -> dict | None:
    """The newest scheduled nightly on main whose head sits under the cut."""
    payload = json.loads(gh_api(
        repo, f"repos/{repo}/{RUN_PAGE}?branch=main&event=schedule&per_page=15"))
    for run in payload.get("workflow_runs", []):  # newest first, as the API returns
        if run.get("event") != "schedule":
            continue
        # The compare response is a full document; read its status field
        # instead of string-matching the body.
        comparison = json.loads(gh_api(
            repo, f"repos/{repo}/compare/{run['head_sha']}...{cut_sha}"))
        if comparison.get("status") == "ahead":  # the nightly head is under the cut
            return run
    return None


def failing_jobs(repo: str, run_id: int) -> list[dict]:
    """Jobs of a run that did not succeed, with their failing steps."""
    payload = json.loads(gh_api(repo, f"repos/{repo}/actions/runs/{run_id}/jobs"))
    report = []
    for job in payload.get("jobs", []):
        if job.get("conclusion") == "success":
            continue
        steps = [step["name"] for step in job.get("steps", [])
                 if step.get("conclusion") not in (None, "success", "skipped")]
        report.append({
            "job": job.get("name"),
            "conclusion": job.get("conclusion"),
            "failed_steps": steps,
            "url": job.get("html_url"),
        })
    return report


def waived(path: Path, run: dict) -> bool:
    """True when the run is the one the baseline records, head and all."""
    if not path.exists():
        return False
    try:
        value = json.loads(path.read_text())
    except ValueError as error:
        raise GateError(
            f"nightly baseline does not parse ({path}): {error}") from None
    entries = value.get("allowed_failure_runs") if isinstance(value, dict) else None
    if not isinstance(entries, list):
        raise GateError(
            f"nightly baseline needs an allowed_failure_runs list ({path})")
    for entry in entries:
        if not isinstance(entry, dict) or entry.get("run_id") != run["id"]:
            continue
        if entry.get("head_sha") != run["head_sha"]:
            raise GateError(
                f"baseline entry for run {run['id']} names head "
                f"{entry.get('head_sha')!r} but the run's head is "
                f"{run['head_sha']}; refresh the baseline to the head it "
                "really reviewed before cutting")
        return True
    return False


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=os.environ.get("GH_REPO", ""),
                        help="owner/name; the release lane passes GITHUB_REPOSITORY")
    parser.add_argument("--baseline", type=Path, default=BASELINE)
    args = parser.parse_args(argv)
    if not args.repo:
        parser.error("a repository is required: pass --repo or set GH_REPO")
    cut_sha = os.environ.get("GITHUB_SHA", "")
    if not cut_sha:
        parser.error("GITHUB_SHA must name the cut head; the workflow supplies it")

    run = ancestor_nightly(args.repo, cut_sha)
    if run is None:
        raise GateError(
            "no scheduled nightly on main sits under this cut (checked the 15 "
            "newest); let one finish or record an explicit baseline decision "
            "before cutting")
    print(f"[rc-cut] nightly run {run['id']} @ {run['head_sha'][:12]} "
          f"({run.get('created_at')}): {run.get('conclusion') or run.get('status')}")
    if run.get("status") != "completed":
        raise GateError(
            f"nightly run {run['id']} is {run['status']}; wait for its verdict "
            "or record it in the baseline to cut over an unread nightly")
    if run["conclusion"] == "success":
        print("[rc-cut] nightly green; the cut may proceed")
        return 0
    report = failing_jobs(args.repo, run["id"])
    print("[rc-cut] nightly failures this cut would ride past:")
    for row in report:
        steps = "; ".join(row["failed_steps"]) or "(no failed step named)"
        print(f"  - {row['job']}: {row['conclusion']} ({steps})")
        print(f"    {row['url']}")
    if waived(args.baseline, run):
        print("[rc-cut] the cut proceeds on an explicitly waived red nightly: "
              f"run {run['id']} is recorded in the baseline")
        return 0
    raise GateError(
        f"red nightly run {run['id']} @ {run['head_sha'][:12]} sits under this "
        "cut; add its run_id and head_sha to scripts/ci/nightly_baseline.json "
        "to cut over it")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GateError as error:
        print(f"[rc-cut] REFUSED: {error}", file=sys.stderr)
        raise SystemExit(1)
