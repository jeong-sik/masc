#!/usr/bin/env python3
"""Count, for recent pull request heads, the instants where every run had ended and one more was still to come.

A watch that wakes a Keeper "when every run of the commit has ended" is early at such an instant
(docs/rfc/RFC-keeper-wakes-when-a-pr-check-finishes.md sections 1.3 and 4.1). This script reads the
runs GitHub holds today for the head of each recent pull request and applies `check_wake_scoring.gaps`
to them, so the share of heads that have such an instant is a measured value and not a guess.

    python3 -I docs/evidence/check-wake-harness-2026-11/probe_head_shas.py \
        --repo jeong-sik/masc --limit 60 --json-out result.json

Reads only: one `gh pr list` and one `gh api repos/<repo>/actions/runs?head_sha=<sha>` per head, so a
probe of N heads is N + 1 requests of the account `gh` is logged in as.

Limits. The runs are the final state of each head, read at `probed_at`. A run is read at the run level
(`created_at`, and `updated_at` once `status` is `completed`), so a job made after its run started is not
seen. A head with a run that has not completed is left out of the gap count (`unsettled`) because the later
runs are not known yet. `updated_at` is the end of the latest attempt of a re-run run.
"""

from __future__ import annotations

import argparse
import collections
import datetime
import json
import pathlib
import statistics
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import check_wake_scoring as scoring  # noqa: E402


def gh_json(*args: str) -> object:
    done = subprocess.run(["gh", *args], check=True, capture_output=True, text=True)
    return json.loads(done.stdout)


def epoch(text: object) -> float | None:
    if not isinstance(text, str):
        return None
    return datetime.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()


def runs_of(answer: object) -> tuple[scoring.Run, ...] | None:
    """`None` when the answer is not the shape GitHub documents for a list of workflow runs."""
    if not isinstance(answer, dict):
        return None
    listed = answer.get("workflow_runs")
    if not isinstance(listed, list):
        return None
    runs: list[scoring.Run] = []
    for item in listed:
        if not isinstance(item, dict):
            return None
        run_id, created = item.get("id"), epoch(item.get("created_at"))
        if not isinstance(run_id, int) or created is None:
            return None
        end = epoch(item.get("updated_at")) if item.get("status") == "completed" else None
        runs.append(
            scoring.Run(
                run_id=run_id,
                workflow=str(item.get("name")),
                event=str(item.get("event")),
                created_at=created,
                end_at=end,
            )
        )
    return tuple(runs)


def stats(values: list[float]) -> dict[str, float | int] | None:
    if not values:
        return None
    return {
        "n": len(values),
        "median_s": round(statistics.median(values), 1),
        "max_s": round(max(values), 1),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True, help="owner/name")
    parser.add_argument("--limit", type=int, required=True, help="how many recent pull requests to read")
    parser.add_argument("--json-out", type=pathlib.Path, required=True)
    args = parser.parse_args()

    pulls = gh_json(
        "pr", "list", "-R", args.repo, "--state", "all", "--limit", str(args.limit),
        "--json", "number,headRefOid",
    )
    if not isinstance(pulls, list):
        raise SystemExit("gh pr list did not answer a list")

    heads: list[tuple[int, str]] = []
    for pull in pulls:
        if isinstance(pull, dict) and isinstance(pull.get("number"), int) and isinstance(pull.get("headRefOid"), str):
            heads.append((pull["number"], pull["headRefOid"]))

    no_runs = unsettled = unreadable = 0
    settled = 0
    heads_with_gap: collections.Counter[str] = collections.Counter()
    gap_lengths: dict[str, list[float]] = collections.defaultdict(list)
    before_check_run = 0
    check_runs_alone_gap = 0
    before_check_run_lengths: list[float] = []
    rows: list[dict[str, object]] = []
    for number, sha in heads:
        answer = gh_json("api", f"repos/{args.repo}/actions/runs?head_sha={sha}&per_page=100")
        runs = runs_of(answer)
        if runs is None:
            unreadable += 1
            continue
        if not runs:
            no_runs += 1
            continue
        if scoring.finish_of(runs) is None:
            unsettled += 1
            continue
        settled += 1
        found = scoring.gaps(runs)
        for event in {gap.event for gap in found}:
            heads_with_gap[event] += 1
        for gap in found:
            gap_lengths[gap.event].append(gap.length_s)
        early = scoring.gaps_before_a_check_run(runs)
        if early:
            before_check_run += 1
            before_check_run_lengths.append(early[0].length_s)
        check_only = tuple(run for run in runs if run.event in scoring.CHECK_EVENTS)
        if scoring.gaps(check_only):
            check_runs_alone_gap += 1
        rows.append(
            {
                "pull": number,
                "head": sha,
                "runs": len(runs),
                "events": sorted({run.event for run in runs}),
                "gaps": [
                    {"run_id": g.run_id, "workflow": g.workflow, "event": g.event, "length_s": round(g.length_s, 1)}
                    for g in found
                ],
                "gap_before_a_check_run": bool(early),
            }
        )

    result = {
        "repo": args.repo,
        "probed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "heads_read": len(heads),
        "unreadable_answers": unreadable,
        "heads_without_runs": no_runs,
        "heads_unsettled": unsettled,
        "heads_settled": settled,
        "settled_heads_with_a_gap_by_later_run_event": dict(heads_with_gap.most_common()),
        "settled_heads_with_any_gap": sum(1 for row in rows if row["gaps"]),
        "settled_heads_where_all_runs_had_ended_before_a_check_run_was_made": before_check_run,
        "first_such_gap_length": stats(before_check_run_lengths),
        "settled_heads_where_the_check_runs_alone_have_a_gap": check_runs_alone_gap,
        "check_events": sorted(scoring.CHECK_EVENTS),
        "gap_length_by_later_run_event": {event: stats(values) for event, values in sorted(gap_lengths.items())},
        "heads": rows,
    }
    args.json_out.write_text(json.dumps(result, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(json.dumps({k: v for k, v in result.items() if k != "heads"}, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
