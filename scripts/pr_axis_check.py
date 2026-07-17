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
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, Callable, Dict, List, Optional, Set, Tuple

GH_RETRIES = 3


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
        return f"| #{self.merged_pr} | `{self.risk_type}` | {files_str} | {self.confidence} |"


# --- RFC number cross-open-PR collision detection (legacy numbered RFCs) -----
# The RFC number allocator was removed (forward slug-only); new RFCs carry no
# number and never match _RFC_CLAIM_RE, so this detector is inert for them. It
# still guards the legacy numbered RFCs that remain on main: two open PRs that
# each add the same RFC-NNNN file would only conflict after one side merges.
# Slug-named RFCs share no monotonic allocation, so they cannot collide here.
_RFC_CLAIM_RE = re.compile(r"(?:^|/)docs/rfc/RFC-(\d{4})-[A-Za-z0-9._-]+\.md$")


@dataclass(frozen=True)
class RfcCollision:
    rfc_number: str
    # Sorted ((pr_number, claiming_file_path), ...) for the colliding PRs.
    prs: Tuple[Tuple[int, str], ...]

    def describe(self) -> str:
        claimants = ", ".join(f"#{n} ({path})" for n, path in self.prs)
        return f"RFC-{self.rfc_number}: claimed by {claimants}"


def _run_gh(args: List[str]) -> Any:
    """Run gh cli and return JSON output."""
    rendered_args = " ".join(args)
    probe = probe_with_retry(["gh", "api"] + args, accept=_decodes_as_json)
    if not probe.ok:
        print(
            f"gh api error for {rendered_args} after {probe.attempts} attempt(s): "
            f"{probe.detail}",
            file=sys.stderr,
        )
        sys.exit(2)
    return json.loads(probe.stdout)


def _require_gh_cli() -> None:
    if shutil.which("gh") is None:
        print("GitHub CLI 'gh' is required for PR axis checks.", file=sys.stderr)
        sys.exit(2)


def _combined_output(result: subprocess.CompletedProcess) -> str:
    combined = "\n".join(
        part.strip() for part in (result.stdout, result.stderr) if part.strip()
    )
    return combined if combined else "<no output>"


@dataclass(frozen=True)
class GhProbe:
    """Outcome of a `gh` invocation, after the retry policy ran."""

    ok: bool
    attempts: int
    # Combined stdout/stderr of the last failing attempt; empty when ok.
    detail: str
    # stdout of the accepted attempt; empty when not ok.
    stdout: str


def _run_capture(argv: List[str]) -> subprocess.CompletedProcess:
    return subprocess.run(argv, capture_output=True, text=True)


def _scripted_runner(
    *responses: Tuple[int, str, str],
) -> Callable[[List[str]], subprocess.CompletedProcess]:
    """Fake runner for [self_test]: yields [responses] in order, repeating the last.

    Each response is (returncode, stdout, stderr).
    """
    remaining = [subprocess.CompletedProcess([], c, o, e) for c, o, e in responses]

    def run(_argv: List[str]) -> subprocess.CompletedProcess:
        return remaining.pop(0) if len(remaining) > 1 else remaining[0]

    return run


def _exit_zero(result: subprocess.CompletedProcess) -> bool:
    return result.returncode == 0


def _decodes_as_json(result: subprocess.CompletedProcess) -> bool:
    if result.returncode != 0:
        return False
    try:
        json.loads(result.stdout)
    except json.JSONDecodeError:
        return False
    return True


def probe_with_retry(
    argv: List[str],
    *,
    accept: Callable[[subprocess.CompletedProcess], bool] = _exit_zero,
    run: Callable[[List[str]], subprocess.CompletedProcess] = _run_capture,
    sleep: Callable[[float], None] = time.sleep,
    retries: int = GH_RETRIES,
) -> GhProbe:
    """Run a `gh` command, retrying with linear backoff until [accept] holds.

    Single retry policy for every `gh` call in this module. Preflight probes
    previously had no retry at all while the query helpers had three, so one
    API timeout hard-failed a required check on an otherwise-green PR.

    [accept] decides what counts as success: exit status alone for preflight
    probes, exit status plus a JSON body for query helpers (a 200 with a
    truncated body is as transient as a timeout).

    [run]/[sleep] are injected so [self_test] can exercise the retry contract
    without a network or a real delay.
    """
    detail = ""
    for attempt in range(1, retries + 1):
        result = run(argv)
        if accept(result):
            return GhProbe(ok=True, attempts=attempt, detail="", stdout=result.stdout)
        detail = _combined_output(result)
        if attempt < retries:
            sleep(attempt)
    return GhProbe(ok=False, attempts=retries, detail=detail, stdout="")


def _exit_preflight_failed(what: str, probe: GhProbe) -> None:
    """Report a preflight failure without asserting which cause produced it.

    `gh` returns non-zero for auth failure, missing repo scope, 5xx, rate
    limiting and network timeouts alike, and the return code does not
    distinguish them. Naming one cause sends the reader to the wrong fix, so
    the cause is left to the captured output.
    """
    print(
        f"PR axis preflight could not {what} after {probe.attempts} attempt(s). "
        "This is a preflight failure, not a finding about the PR: its axis "
        "risk was not evaluated. The cause (credentials, repository scope, "
        f"rate limiting, or a transient network/5xx error) is below.\n"
        f"Details: {probe.detail}",
        file=sys.stderr,
    )
    sys.exit(2)


def _require_gh_auth() -> None:
    _require_gh_cli()
    probe = probe_with_retry(["gh", "auth", "status", "--hostname", "github.com"])
    if not probe.ok:
        _exit_preflight_failed("verify gh auth for github.com", probe)


def _require_gh_repo_read(owner: str, repo: str) -> None:
    _require_gh_auth()
    repo_slug = f"{owner}/{repo}"
    probe = probe_with_retry(
        ["gh", "api", f"repos/{repo_slug}", "--jq", ".full_name"]
    )
    if not probe.ok:
        _exit_preflight_failed(f"read repo {repo_slug}", probe)


def _run_gh_graphql(query: str) -> dict:
    """Run gh graphql query and return data."""
    probe = probe_with_retry(
        ["gh", "api", "graphql", "-f", f"query={query}"], accept=_decodes_as_json
    )
    if not probe.ok:
        print(
            f"gh graphql error after {probe.attempts} attempt(s): {probe.detail}",
            file=sys.stderr,
        )
        sys.exit(2)
    return json.loads(probe.stdout)


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
        print(
            "Cannot determine repository. Set GITHUB_REPOSITORY or run in a gh repo.",
            file=sys.stderr,
        )
        sys.exit(2)
    data = json.loads(result.stdout)
    return data["owner"]["login"], data["name"]


def get_pr_base_info(
    pr_number: int, owner: str, repo: str
) -> Tuple[Optional[str], Optional[str]]:
    """Get the base SHA and base ref name of an open PR."""
    resp = _run_gh([f"/repos/{owner}/{repo}/pulls/{pr_number}"])
    base = resp.get("base", {})
    return base.get("sha"), base.get("ref")


def merge_commit_already_in_base(
    merge_commit_sha: str, pr_base_sha: str, owner: str, repo: str
) -> bool:
    """Check if a merged PR's merge commit is already an ancestor of (or equal to) the PR base."""
    if merge_commit_sha == pr_base_sha:
        return True
    # GitHub compare API: compare/{base}...{head}
    # status == "ahead"   -> head is ahead of base (base is ancestor of head)
    # status == "identical" -> same
    resp = _run_gh(
        [f"/repos/{owner}/{repo}/compare/{merge_commit_sha}...{pr_base_sha}"]
    )
    status = resp.get("status", "")
    return status in ("ahead", "identical")


def _payload_preview(payload: Any) -> str:
    rendered = json.dumps(payload, sort_keys=True)
    if len(rendered) > 1000:
        return rendered[:997] + "..."
    return rendered


def _pr_file_items(resp: Any, pr_number: int, page: int) -> List[Dict[str, Any]]:
    if not isinstance(resp, list):
        print(
            f"gh api unexpected PR files payload for #{pr_number} page {page}: "
            f"expected list, got {type(resp).__name__}: {_payload_preview(resp)}",
            file=sys.stderr,
        )
        sys.exit(2)

    items: List[Dict[str, Any]] = []
    for idx, item in enumerate(resp):
        if not isinstance(item, dict) or not isinstance(item.get("filename"), str):
            print(
                f"gh api unexpected PR files item for #{pr_number} page {page} "
                f"at index {idx}: {_payload_preview(item)}",
                file=sys.stderr,
            )
            sys.exit(2)
        items.append(item)
    return items


def get_pr_files(pr_number: int, owner: str, repo: str) -> Set[str]:
    """Get set of file paths changed in a PR."""
    files: Set[str] = set()
    page = 1
    while True:
        resp = _run_gh(
            [f"/repos/{owner}/{repo}/pulls/{pr_number}/files?per_page=100&page={page}"]
        )
        items = _pr_file_items(resp, pr_number, page)
        for item in items:
            files.add(item["filename"])
        if len(items) < 100:
            break
        page += 1
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
        baseRefName
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

    pr_base_sha, pr_base_ref = get_pr_base_info(pr_number, owner, repo)
    if not pr_base_sha:
        print(
            f"Warning: could not determine base SHA for PR #{pr_number}",
            file=sys.stderr,
        )

    recently_merged = get_recently_merged_prs(owner, repo, hours, limit)
    risks: List[AxisRisk] = []

    for merged in recently_merged:
        merged_num = merged["number"]
        if merged_num == pr_number:
            continue
        merged_title = merged["title"]
        merged_files = {
            node["path"] for node in merged.get("files", {}).get("nodes", [])
        }

        overlap = open_files & merged_files
        if not overlap:
            continue

        # This guard is about stale PRs caused by recent merges into the same
        # target branch. Stacked PRs can be merged into another feature branch;
        # treating those as mainline merges creates a false BUILD_DEP_BREAK
        # blocker for their own base PR.
        merged_base_ref = merged.get("baseRefName")
        if pr_base_ref and merged_base_ref and merged_base_ref != pr_base_ref:
            continue

        # Skip if the merged PR is already included in the current PR's base.
        # mergeCommit.oid is fetched up-front in get_recently_merged_prs so we
        # don't pay a per-PR REST round-trip here when scanning many PRs.
        if pr_base_sha:
            merge_commit = (merged.get("mergeCommit") or {}).get("oid")
            if merge_commit and merge_commit_already_in_base(
                merge_commit, pr_base_sha, owner, repo
            ):
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

        risks.append(
            AxisRisk(
                risk_type=risk_type,
                merged_pr=merged_num,
                merged_title=merged_title,
                overlap_files=sorted(overlap),
                confidence=confidence,
            )
        )

    return risks


def scan_all_open_prs(
    owner: str, repo: str, hours: int, limit: int
) -> Dict[int, List[AxisRisk]]:
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
    open_prs = (
        data.get("data", {})
        .get("repository", {})
        .get("pullRequests", {})
        .get("nodes", [])
    )

    results: Dict[int, List[AxisRisk]] = {}
    for pr in open_prs:
        pr_num = pr["number"]
        print(f"Scanning PR #{pr_num}: {pr['title']}", file=sys.stderr)
        risks = check_pr_axis_stale(pr_num, owner, repo, hours, limit)
        if risks:
            results[pr_num] = risks

    return results


def detect_rfc_collisions(open_prs: List[Dict[str, Any]]) -> List[RfcCollision]:
    """Find RFC numbers newly claimed by two or more open PRs.

    Pure over its inputs so the self-test can feed synthetic PRs. Each entry in
    ``open_prs`` is ``{"number": int, "added_rfc_files": [path, ...]}`` where the
    paths are RFC files ADDED (not modified) by that PR. A number claimed by a
    single PR — even across multiple files (multi-phase) — is not a collision;
    only the same new number across distinct PRs is.
    """
    by_number: Dict[str, List[Tuple[int, str]]] = {}
    for pr in open_prs:
        number_seen: Set[str] = set()
        for path in pr.get("added_rfc_files", []):
            match = _RFC_CLAIM_RE.search(path)
            if match is None:
                continue
            number = match.group(1)
            if number in number_seen:
                continue  # same PR claiming one number across files — one claim
            number_seen.add(number)
            by_number.setdefault(number, []).append((int(pr["number"]), path))

    collisions: List[RfcCollision] = []
    for number, claims in sorted(by_number.items()):
        distinct_prs = {pr_num for pr_num, _ in claims}
        if len(distinct_prs) >= 2:
            collisions.append(RfcCollision(number, tuple(sorted(claims))))
    return collisions


def get_open_prs_with_added_rfc_files(owner: str, repo: str) -> List[Dict[str, Any]]:
    """Fetch open PRs and the RFC files each one ADDS (GraphQL changeType)."""
    query = f"""
query {{
  repository(owner: "{owner}", name: "{repo}") {{
    pullRequests(states: OPEN, first: 50) {{
      nodes {{
        number
        title
        files(first: 100) {{
          nodes {{ path changeType }}
        }}
      }}
    }}
  }}
}}
"""
    data = _run_gh_graphql(query)
    nodes = (
        data.get("data", {})
        .get("repository", {})
        .get("pullRequests", {})
        .get("nodes", [])
    )
    result: List[Dict[str, Any]] = []
    for pr in nodes:
        file_nodes = (pr.get("files") or {}).get("nodes") or []
        added = [
            f["path"]
            for f in file_nodes
            if f.get("changeType") == "ADDED"
            and _RFC_CLAIM_RE.search(f.get("path", ""))
        ]
        if added:
            result.append(
                {
                    "number": pr["number"],
                    "title": pr.get("title", ""),
                    "added_rfc_files": added,
                }
            )
    return result


def self_test() -> int:
    """Fixture-based check of detect_rfc_collisions (clean + colliding cases)."""
    clean = [
        {"number": 1, "added_rfc_files": ["docs/rfc/RFC-0289-foo.md"]},
        {"number": 2, "added_rfc_files": ["docs/rfc/RFC-0290-bar.md"]},
    ]
    assert detect_rfc_collisions(clean) == [], "distinct numbers must not collide"
    print("self-test: distinct RFC numbers -> no collision (PASS)")

    buggy = [
        {
            "number": 22158,
            "added_rfc_files": ["docs/rfc/RFC-0289-keeper-progress-lib-split.md"],
        },
        {
            "number": 22144,
            "added_rfc_files": ["docs/rfc/RFC-0289-closed-sse-event-type-sum.md"],
        },
    ]
    collisions = detect_rfc_collisions(buggy)
    assert len(collisions) == 1, f"expected 1 collision, got {len(collisions)}"
    assert collisions[0].rfc_number == "0289"
    assert {n for n, _ in collisions[0].prs} == {22144, 22158}
    print(
        f"self-test: two open PRs claim RFC-0289 -> {collisions[0].describe()} (PASS)"
    )

    multiphase = [
        {
            "number": 30,
            "added_rfc_files": ["docs/rfc/RFC-0300-a.md", "docs/rfc/RFC-0300-b.md"],
        },
    ]
    assert detect_rfc_collisions(multiphase) == [], (
        "single PR multi-file is not a collision"
    )
    print("self-test: single PR, one number across files -> no collision (PASS)")

    noise = [
        {"number": 40, "added_rfc_files": ["docs/rfc/README.md", "src/RFC-0289-x.txt"]},
        {"number": 41, "added_rfc_files": ["docs/rfc/RFC-0289-real.md"]},
    ]
    assert detect_rfc_collisions(noise) == [], "non-RFC-claim paths must not collide"
    print("self-test: non-RFC paths ignored -> no collision (PASS)")

    # Preflight retry contract. Without a retry a single API timeout hard-failed
    # a required check on an otherwise-green PR (#24574, run 29491927277: the
    # repo probe hit `dial tcp ...: i/o timeout`; the rerun passed untouched).
    transient = probe_with_retry(
        ["gh"],
        run=_scripted_runner(
            (1, "", "dial tcp: i/o timeout"),
            (1, "", "dial tcp: i/o timeout"),
            (0, "ok", ""),
        ),
        sleep=lambda _: None,
    )
    assert transient.ok, "a transient gh failure must be absorbed by the retry"
    assert transient.attempts == 3, f"expected 3 attempts, got {transient.attempts}"
    assert transient.detail == "", "a recovered probe must not carry failure detail"
    print("self-test: transient gh failure -> absorbed on attempt 3 (PASS)")

    persistent = probe_with_retry(
        ["gh"],
        run=_scripted_runner((1, "", "The token in GH_TOKEN is invalid.")),
        sleep=lambda _: None,
    )
    assert not persistent.ok, "a persistent gh failure must not report ok"
    assert persistent.attempts == GH_RETRIES
    assert "GH_TOKEN" in persistent.detail, (
        "the last failure's output must reach the caller so the reader can "
        "tell auth failure from a network blip"
    )
    print("self-test: persistent gh failure -> reported with detail (PASS)")

    # The query helpers accept only a decodable JSON body: a zero exit with a
    # truncated body is transient, so it must be retried rather than parsed.
    json_probe = probe_with_retry(
        ["gh"],
        accept=_decodes_as_json,
        run=_scripted_runner((0, '{"ok":', ""), (0, '{"ok":true}', "")),
        sleep=lambda _: None,
    )
    assert json_probe.ok, "a truncated JSON body must be retried, not parsed"
    assert json_probe.attempts == 2
    assert json.loads(json_probe.stdout) == {"ok": True}
    print("self-test: exit-zero with truncated JSON -> retried (PASS)")

    print("pr_axis_check self-test: all cases passed")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="PR Axis Cross-Check")
    parser.add_argument("--pr", type=int, help="PR number to check")
    parser.add_argument(
        "--scan-all-open", action="store_true", help="Scan all open PRs"
    )
    parser.add_argument(
        "--hours", type=int, default=24, help="Lookback window in hours"
    )
    parser.add_argument(
        "--limit", type=int, default=20, help="Max recent merged PRs to check"
    )
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    parser.add_argument(
        "--check-rfc-collisions",
        action="store_true",
        help="Scan all open PRs for the same newly-claimed RFC number",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run fixture-based self-test of RFC collision detection",
    )
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    _require_gh_cli()
    owner, repo = get_repo_slug()
    _require_gh_repo_read(owner, repo)

    if args.check_rfc_collisions:
        open_prs = get_open_prs_with_added_rfc_files(owner, repo)
        collisions = detect_rfc_collisions(open_prs)
        if collisions:
            print("RFC number collisions among open PRs:\n")
            for collision in collisions:
                print(f"  - {collision.describe()}")
            print(
                "\nTwo open PRs cannot both claim the same RFC number. The number "
                "allocator was removed; rename one RFC file to a free number, or "
                "give new RFCs a slug-only filename so they share no number."
            )
            return 1
        print("No RFC number collisions among open PRs.")
        return 0

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
            print(
                json.dumps(
                    {
                        str(pr_num): [
                            {
                                "type": r.risk_type,
                                "merged_pr": r.merged_pr,
                                "confidence": r.confidence,
                            }
                            for r in risks
                        ]
                        for pr_num, risks in blockers.items()
                    },
                    indent=2,
                )
            )
        else:
            if warnings:
                for pr_num, risks in warnings.items():
                    print(
                        f"\nPR #{pr_num} LOW-confidence overlaps (informational only):"
                    )
                    for r in risks:
                        print(
                            f"  - {r.risk_type} from #{r.merged_pr} ({r.confidence}): {', '.join(r.overlap_files[:3])}"
                        )
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
        print(
            json.dumps(
                [
                    {
                        "type": r.risk_type,
                        "merged_pr": r.merged_pr,
                        "confidence": r.confidence,
                    }
                    for r in single_blockers
                ],
                indent=2,
            )
        )
    else:
        if single_warnings:
            print(
                f"Found {len(single_warnings)} LOW-confidence overlap(s) for PR #{args.pr} (informational only):\n"
            )
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
            print(
                "Recommended action: rebase on latest main and run `dune build @check`."
            )
            return 1
        if not single_warnings:
            print(f"No axis risks found for PR #{args.pr}.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
