#!/usr/bin/env python3
"""PR Axis Cross-Check — detect stale PRs from recent main merges.

Scans recently merged PRs and checks if their changes make an open PR stale.
Uses GitHub CLI (gh) for API access.

Usage:
    python scripts/pr_axis_check.py --pr 123 --hours 24 --limit 20
    python scripts/pr_axis_check.py --scan-all-open --hours 24

Exit codes:
    0 — no risks found
    1 — one or more risks detected
    2 — runtime error
"""

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Dict, List, Optional, Set, Tuple


@dataclass(frozen=True)
class AxisRisk:
    risk_type: str
    merged_pr: int
    merged_title: str
    overlap_files: List[str]
    confidence: str

    def to_markdown(self) -> str:
        files_str = ", ".join(self.overlap_files[:3])
        if len(self.overlap_files) > 3:
            files_str += f" (+{len(self.overlap_files) - 3} more)"
        return (
            f"| #{self.merged_pr} | `{self.risk_type}` | {files_str} | {self.confidence} |"
        )


def _run_gh(args: List[str]) -> dict:
    """Run gh cli and return JSON output."""
    result = subprocess.run(
        ["gh", "api"] + args,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"gh api error: {result.stderr}", file=sys.stderr)
        sys.exit(2)
    return json.loads(result.stdout)


def _run_gh_graphql(query: str) -> dict:
    """Run gh graphql query and return data."""
    result = subprocess.run(
        ["gh", "api", "graphql", "-f", f"query={query}"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"gh graphql error: {result.stderr}", file=sys.stderr)
        sys.exit(2)
    return json.loads(result.stdout)


def get_repo_slug() -> Tuple[str, str]:
    """Extract owner/repo from gh repo view."""
    result = subprocess.run(
        ["gh", "repo", "view", "--json", "owner,name"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        # Fallback from GITHUB_REPOSITORY env var
        repo = os.environ.get("GITHUB_REPOSITORY", "")
        if "/" in repo:
            return tuple(repo.split("/", 1))  # type: ignore[return-value]
        print("Cannot determine repository. Set GITHUB_REPOSITORY or run in a gh repo.", file=sys.stderr)
        sys.exit(2)
    data = json.loads(result.stdout)
    return data["owner"]["login"], data["name"]


def get_pr_base_sha(pr_number: int, owner: str, repo: str) -> Optional[str]:
    """Get the base SHA of an open PR."""
    resp = _run_gh([f"/repos/{owner}/{repo}/pulls/{pr_number}"])
    return resp.get("base", {}).get("sha")


def merge_commit_already_in_base(
    merge_commit_sha: str, pr_base_sha: str, owner: str, repo: str
) -> bool:
    """Check if a merged PR's merge commit is already an ancestor of (or equal to) the PR base."""
    if merge_commit_sha == pr_base_sha:
        return True
    # GitHub compare API: compare/{base}...{head}
    # status == "ahead"   -> head is ahead of base (base is ancestor of head)
    # status == "identical" -> same
    resp = _run_gh([f"/repos/{owner}/{repo}/compare/{merge_commit_sha}...{pr_base_sha}"])
    status = resp.get("status", "")
    return status in ("ahead", "identical")


def get_pr_files(pr_number: int, owner: str, repo: str) -> Set[str]:
    """Get set of file paths changed in a PR."""
    resp = _run_gh([
        f"/repos/{owner}/{repo}/pulls/{pr_number}/files",
        "--paginate",
    ])
    if not isinstance(resp, list):
        payload = json.dumps(resp, sort_keys=True)
        if len(payload) > 1000:
            payload = payload[:997] + "..."
        print(
            f"gh api unexpected PR files payload for #{pr_number}: "
            f"expected list, got {type(resp).__name__}: {payload}",
            file=sys.stderr,
        )
        sys.exit(2)

    files: Set[str] = set()
    for idx, item in enumerate(resp):
        if not isinstance(item, dict) or not isinstance(item.get("filename"), str):
            payload = json.dumps(item, sort_keys=True)
            if len(payload) > 1000:
                payload = payload[:997] + "..."
            print(
                f"gh api unexpected PR files item for #{pr_number} at index {idx}: "
                f"{payload}",
                file=sys.stderr,
            )
            sys.exit(2)
        files.add(item["filename"])
    return files


def get_recently_merged_prs(
    owner: str, repo: str, hours: int, limit: int
) -> List[dict]:
    """Get recently merged PRs with their changed files."""
    since = (datetime.now() - timedelta(hours=hours)).isoformat()
    query = f"""
query {{
  repository(owner: "{owner}", name: "{repo}") {{
    pullRequests(
      states: MERGED
      first: {limit}
      orderBy: {{field: UPDATED_AT, direction: DESC}}
    ) {{
      nodes {{
        number
        title
        mergedAt
        mergeCommit {{ oid }}
        files(first: 100) {{
          nodes {{ path }}
        }}
      }}
    }}
  }}
}}
"""
    data = _run_gh_graphql(query)
    repo_data = data.get("data", {}).get("repository", {})
    prs = repo_data.get("pullRequests", {}).get("nodes", [])
    # Filter by mergedAt
    filtered = []
    for pr in prs:
        merged_at = pr.get("mergedAt", "")
        if merged_at and merged_at >= since:
            filtered.append(pr)
    return filtered


def _get_dune_libraries_from_diff(owner: str, repo: str, pr_number: int) -> Set[str]:
    """Check if a merged PR changed dune library dependencies."""
    # This is a heuristic: check if any dune file was changed
    files = get_pr_files(pr_number, owner, repo)
    dune_files = {f for f in files if f.endswith("/dune") or f == "dune"}
    return dune_files


def _touches_dune_deps(pr_number: int, owner: str, repo: str) -> bool:
    """Check if PR changed any dune file (potential dependency change)."""
    return len(_get_dune_libraries_from_diff(owner, repo, pr_number)) > 0


def check_pr_axis_stale(
    pr_number: int,
    owner: str,
    repo: str,
    hours: int = 24,
    limit: int = 20,
) -> List[AxisRisk]:
    """Check if an open PR is at risk of being stale from recent merges."""
    open_files = get_pr_files(pr_number, owner, repo)
    if not open_files:
        print(f"Warning: no files found for PR #{pr_number}", file=sys.stderr)
        return []

    pr_base_sha = get_pr_base_sha(pr_number, owner, repo)
    if not pr_base_sha:
        print(f"Warning: could not determine base SHA for PR #{pr_number}", file=sys.stderr)

    recently_merged = get_recently_merged_prs(owner, repo, hours, limit)
    risks: List[AxisRisk] = []

    for merged in recently_merged:
        merged_num = merged["number"]
        merged_title = merged["title"]
        merged_files = {node["path"] for node in merged.get("files", {}).get("nodes", [])}

        overlap = open_files & merged_files
        if not overlap:
            continue

        # Skip if the merged PR is already included in the current PR's base.
        # mergeCommit.oid is fetched up-front in get_recently_merged_prs so we
        # don't pay a per-PR REST round-trip here when scanning many PRs.
        if pr_base_sha:
            merge_commit = (merged.get("mergeCommit") or {}).get("oid")
            if merge_commit and merge_commit_already_in_base(merge_commit, pr_base_sha, owner, repo):
                continue

        # Determine risk type and confidence
        confidence = "LOW"
        risk_type = "FILE_OVERLAP"

        # Check if dune files changed
        dune_overlap = {f for f in overlap if f.endswith("/dune") or f == "dune"}
        if dune_overlap:
            risk_type = "BUILD_DEP_BREAK"
            confidence = "HIGH"

        # Check if .mli files changed (potential signature change)
        mli_overlap = {f for f in overlap if f.endswith(".mli")}
        if mli_overlap and confidence != "HIGH":
            risk_type = "API_SIGNATURE_CHANGE"
            confidence = "HIGH"

        # Check if types/modules changed
        type_files = {f for f in overlap if "types" in f or "type" in f}
        if type_files and confidence == "LOW":
            risk_type = "TYPE_CONFLICT"
            confidence = "MEDIUM"

        # High file overlap = higher confidence
        if len(overlap) > 5 and confidence == "LOW":
            confidence = "MEDIUM"

        risks.append(AxisRisk(
            risk_type=risk_type,
            merged_pr=merged_num,
            merged_title=merged_title,
            overlap_files=sorted(overlap),
            confidence=confidence,
        ))

    return risks


def scan_all_open_prs(owner: str, repo: str, hours: int, limit: int) -> Dict[int, List[AxisRisk]]:
    """Scan all open PRs for axis risks."""
    query = f"""
query {{
  repository(owner: "{owner}", name: "{repo}") {{
    pullRequests(states: OPEN, first: 50) {{
      nodes {{
        number
        title
        isDraft
      }}
    }}
  }}
}}
"""
    data = _run_gh_graphql(query)
    open_prs = data.get("data", {}).get("repository", {}).get("pullRequests", {}).get("nodes", [])

    results: Dict[int, List[AxisRisk]] = {}
    for pr in open_prs:
        pr_num = pr["number"]
        print(f"Scanning PR #{pr_num}: {pr['title']}", file=sys.stderr)
        risks = check_pr_axis_stale(pr_num, owner, repo, hours, limit)
        if risks:
            results[pr_num] = risks

    return results


def main() -> int:
    parser = argparse.ArgumentParser(description="PR Axis Cross-Check")
    parser.add_argument("--pr", type=int, help="PR number to check")
    parser.add_argument("--scan-all-open", action="store_true", help="Scan all open PRs")
    parser.add_argument("--hours", type=int, default=24, help="Lookback window in hours")
    parser.add_argument("--limit", type=int, default=20, help="Max recent merged PRs to check")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    args = parser.parse_args()

    owner, repo = get_repo_slug()

    def _block(r: AxisRisk) -> bool:
        return r.confidence != "LOW"

    if args.scan_all_open:
        results = scan_all_open_prs(owner, repo, args.hours, args.limit)
        # Partition into blockers vs warnings
        blockers: Dict[int, List[AxisRisk]] = {}
        warnings: Dict[int, List[AxisRisk]] = {}
        for pr_num, risks in results.items():
            b = [r for r in risks if _block(r)]
            w = [r for r in risks if not _block(r)]
            if b:
                blockers[pr_num] = b
            if w:
                warnings[pr_num] = w
        if args.json:
            print(json.dumps({
                str(pr_num): [
                    {"type": r.risk_type, "merged_pr": r.merged_pr, "confidence": r.confidence}
                    for r in risks
                ]
                for pr_num, risks in blockers.items()
            }, indent=2))
        else:
            if warnings:
                for pr_num, risks in warnings.items():
                    print(f"\nPR #{pr_num} LOW-confidence overlaps (informational only):")
                    for r in risks:
                        print(f"  - {r.risk_type} from #{r.merged_pr} ({r.confidence}): {', '.join(r.overlap_files[:3])}")
            if blockers:
                print(f"\nFound blocking risks in {len(blockers)} PR(s):\n")
                for pr_num, risks in blockers.items():
                    print(f"PR #{pr_num}:")
                    for r in risks:
                        print(f"  - {r.risk_type} from #{r.merged_pr} ({r.confidence})")
                return 1
            if not warnings:
                print("No axis risks found in any open PRs.")
        return 0

    if not args.pr:
        parser.error("Either --pr or --scan-all-open is required")

    single_risks = check_pr_axis_stale(args.pr, owner, repo, args.hours, args.limit)
    single_blockers = [r for r in single_risks if _block(r)]
    single_warnings = [r for r in single_risks if not _block(r)]

    if args.json:
        print(json.dumps([
            {"type": r.risk_type, "merged_pr": r.merged_pr, "confidence": r.confidence}
            for r in single_blockers
        ], indent=2))
    else:
        if single_warnings:
            print(f"Found {len(single_warnings)} LOW-confidence overlap(s) for PR #{args.pr} (informational only):\n")
            print("| Merged PR | Risk Type | Overlap Files | Confidence |")
            print("|-----------|-----------|---------------|------------|")
            for r in single_warnings:
                print(r.to_markdown())
            print()
        if single_blockers:
            total = len(single_blockers)
            print(f"Found {total} blocking risk(s) for PR #{args.pr}:\n")
            print("| Merged PR | Risk Type | Overlap Files | Confidence |")
            print("|-----------|-----------|---------------|------------|")
            for r in single_blockers:
                print(r.to_markdown())
            print()
            print("Recommended action: rebase on latest main and run `dune build @check`.")
            return 1
        if not single_warnings:
            print(f"No axis risks found for PR #{args.pr}.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
