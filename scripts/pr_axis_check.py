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
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, Dict, List, Optional, Set, Tuple

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


def _run_gh(args: List[str], *, allow_not_found: bool = False) -> Any:
    """Run gh cli and return JSON output.

    With ``allow_not_found`` an HTTP 404 returns ``None`` instead of exiting:
    the caller owns the typed meaning of an unreachable object (e.g. a merge
    commit orphaned when its stacked parent branch was auto-deleted)."""
    rendered_args = " ".join(args)
    for attempt in range(1, GH_RETRIES + 1):
        result = subprocess.run(
            ["gh", "api"] + args,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            if allow_not_found and "(HTTP 404)" in result.stderr:
                return None
            if attempt < GH_RETRIES:
                time.sleep(attempt)
                continue
            print(
                f"gh api error for {rendered_args}: {result.stderr.strip()}",
                file=sys.stderr,
            )
            sys.exit(2)
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            if attempt < GH_RETRIES:
                time.sleep(attempt)
                continue
            print(
                f"gh api invalid JSON for {rendered_args}: {exc}; "
                f"stdout={result.stdout[:500]!r}; stderr={result.stderr.strip()}",
                file=sys.stderr,
            )
            sys.exit(2)
    raise AssertionError("unreachable gh api retry loop")


def _require_gh_cli() -> None:
    if shutil.which("gh") is None:
        print("GitHub CLI 'gh' is required for PR axis checks.", file=sys.stderr)
        sys.exit(2)


def _combined_output(result: subprocess.CompletedProcess) -> str:
    combined = "\n".join(
        part.strip() for part in (result.stdout, result.stderr) if part.strip()
    )
    return combined if combined else "<no output>"


def _require_gh_auth() -> None:
    _require_gh_cli()
    status = subprocess.run(
        ["gh", "auth", "status", "--hostname", "github.com"],
        capture_output=True,
        text=True,
    )
    if status.returncode != 0:
        print(
            "gh auth is not usable for github.com; refresh credentials before "
            f"running PR axis checks. Details: {_combined_output(status)}",
            file=sys.stderr,
        )
        sys.exit(2)


def _require_gh_repo_read(owner: str, repo: str) -> None:
    _require_gh_auth()
    repo_slug = f"{owner}/{repo}"
    repo_check = subprocess.run(
        ["gh", "api", f"repos/{repo_slug}", "--jq", ".full_name"],
        capture_output=True,
        text=True,
    )
    if repo_check.returncode != 0:
        print(
            "gh credentials are authenticated but cannot read repo "
            f"{repo_slug}; check token repository permissions before PR axis "
            f"checks. Details: {_combined_output(repo_check)}",
            file=sys.stderr,
        )
        sys.exit(2)


def _run_gh_graphql(query: str) -> dict:
    """Run gh graphql query and return data."""
    for attempt in range(1, GH_RETRIES + 1):
        result = subprocess.run(
            ["gh", "api", "graphql", "-f", f"query={query}"],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            if attempt < GH_RETRIES:
                time.sleep(attempt)
                continue
            print(f"gh graphql error: {result.stderr.strip()}", file=sys.stderr)
            sys.exit(2)
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            if attempt < GH_RETRIES:
                time.sleep(attempt)
                continue
            print(
                f"gh graphql invalid JSON: {exc}; "
                f"stdout={result.stdout[:500]!r}; stderr={result.stderr.strip()}",
                file=sys.stderr,
            )
            sys.exit(2)
    raise AssertionError("unreachable gh graphql retry loop")


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


def merged_pr_in_scope(
    pr_base_ref: Optional[str], merged_base_ref: Optional[str]
) -> bool:
    """A merged PR is comparison-relevant only when it landed on the open PR's
    own base branch: default-branch PRs compare against default-branch merges,
    stacked PRs compare against sibling merges into the same parent branch.
    Missing refs stay in scope (conservative: never silently drop a signal)."""
    if not pr_base_ref or not merged_base_ref:
        return True
    return merged_base_ref == pr_base_ref


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
        [f"/repos/{owner}/{repo}/compare/{merge_commit_sha}...{pr_base_sha}"],
        allow_not_found=True,
    )
    if resp is None:
        # The merge commit is unreachable — typical for a stacked child whose
        # parent branch was auto-deleted after folding. Containment cannot be
        # proven, so do not skip: let the overlap analysis run.
        print(
            f"axis compare 404 for {merge_commit_sha[:12]}...{pr_base_sha[:12]}: "
            "unreachable merge commit, treating as not-contained",
            file=sys.stderr,
        )
        return False
    status = resp.get("status", "")
    return status in ("ahead", "identical")


_TREE_BLOBS_CACHE: Dict[str, Optional[Dict[str, str]]] = {}


def _tree_blobs(commit_sha: str, owner: str, repo: str) -> Optional[Dict[str, str]]:
    """Map every blob path in a commit's tree to its blob SHA.

    Returns None when the tree is unreachable or GitHub truncated it, so the
    caller falls back to the conservative path instead of comparing a partial
    tree against a whole one.
    """
    cached = _TREE_BLOBS_CACHE.get(commit_sha)
    if cached is not None or commit_sha in _TREE_BLOBS_CACHE:
        return cached
    resp = _run_gh(
        [f"/repos/{owner}/{repo}/git/trees/{commit_sha}?recursive=1"],
        allow_not_found=True,
    )
    blobs: Optional[Dict[str, str]] = None
    if isinstance(resp, dict) and not resp.get("truncated"):
        blobs = {
            entry["path"]: entry["sha"]
            for entry in resp.get("tree", [])
            if isinstance(entry, dict)
            and entry.get("type") == "blob"
            and entry.get("path")
            and entry.get("sha")
        }
    _TREE_BLOBS_CACHE[commit_sha] = blobs
    return blobs


def merged_delta_is_present_in_base(
    merged_files: Set[str],
    merge_commit_sha: str,
    pr_base_sha: str,
    owner: str,
    repo: str,
) -> bool:
    """Check whether a merged PR's result already stands in the PR base.

    A force-restack rewrites commits, so the original merge commit stops being
    an ancestor even though the same delta is present. Compare content instead
    of ancestry: every path the merged PR touched must carry the same blob SHA
    in the base as it does at the merge commit. A path absent from both trees
    matches too, which is how a merged deletion reads.

    Content equality is stricter than patch equivalence. A base that changed
    those files further returns False and the overlap analysis runs, which is
    the conservative direction.
    """
    if not merged_files:
        return False
    merged_tree = _tree_blobs(merge_commit_sha, owner, repo)
    base_tree = _tree_blobs(pr_base_sha, owner, repo)
    if merged_tree is None or base_tree is None:
        return False
    return all(merged_tree.get(path) == base_tree.get(path) for path in merged_files)


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
        mergeCommit {{ oid parents(first: 1) {{ nodes {{ oid }} }} }}
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


# The dune fields that decide what a build links. Changing one of them can
# break a PR compiled against the old set; changing (name), a (rule), or a
# comment in the same file cannot. BUILD_DEP_BREAK is a claim about these
# forms, so it is these forms that get compared -- not the file's name.
_DUNE_DEPENDENCY_FIELDS = ("libraries", "pps", "instrumentation")

_DUNE_FIELD_RE = re.compile(r"\((" + "|".join(_DUNE_DEPENDENCY_FIELDS) + r")(?=[\s)])")


def _strip_dune_comments(source: str) -> str:
    """Drop `;` comments from dune source, leaving string literals intact."""
    out: List[str] = []
    in_string = False
    in_comment = False
    i = 0
    while i < len(source):
        ch = source[i]
        if in_comment:
            if ch == "\n":
                in_comment = False
                out.append(ch)
            i += 1
            continue
        if in_string:
            out.append(ch)
            if ch == "\\" and i + 1 < len(source):
                out.append(source[i + 1])
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
        elif ch == ";":
            in_comment = True
            i += 1
            continue
        else:
            out.append(ch)
        i += 1
    return "".join(out)


def dune_dependency_forms(source: str) -> List[str]:
    """Every dependency stanza in a dune file, whitespace-normalised and sorted.

    Two revisions produce equal lists exactly when they declare the same
    dependencies, however much else moved in the file. The stanza text is kept
    raw rather than parsed into atoms so that `(re_export foo)`, variables and
    `%{...}` forms compare by what they say instead of by what we guess they
    mean.
    """
    text = _strip_dune_comments(source)
    forms: List[str] = []
    for match in _DUNE_FIELD_RE.finditer(text):
        start = match.start()
        depth = 0
        i = start
        while i < len(text):
            ch = text[i]
            if ch == '"':
                i += 1
                while i < len(text) and text[i] != '"':
                    i += 2 if text[i] == "\\" else 1
            elif ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    forms.append(" ".join(text[start : i + 1].split()))
                    break
            i += 1
    return sorted(forms)


_BLOB_TEXT_CACHE: Dict[str, Optional[str]] = {}


def _blob_text(blob_sha: str, owner: str, repo: str) -> Optional[str]:
    """Decode a blob to text. None when it is unreachable or not UTF-8."""
    if blob_sha in _BLOB_TEXT_CACHE:
        return _BLOB_TEXT_CACHE[blob_sha]
    resp = _run_gh(
        [f"/repos/{owner}/{repo}/git/blobs/{blob_sha}"], allow_not_found=True
    )
    text: Optional[str] = None
    if isinstance(resp, dict) and resp.get("encoding") == "base64":
        try:
            text = base64.b64decode(resp.get("content", "")).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            text = None
    _BLOB_TEXT_CACHE[blob_sha] = text
    return text


def dune_deps_changed(
    paths: Set[str], after_sha: str, before_sha: str, owner: str, repo: str
) -> Optional[bool]:
    """Whether any of `paths` changed a dune dependency stanza between two commits.

    None means the answer is not knowable here -- an unreachable or truncated
    tree, or a blob we could not decode. Callers must keep their conservative
    verdict on None rather than reading it as "nothing changed".
    """
    after = _tree_blobs(after_sha, owner, repo)
    before = _tree_blobs(before_sha, owner, repo)
    if after is None or before is None:
        return None
    for path in sorted(paths):
        after_blob = after.get(path)
        before_blob = before.get(path)
        if after_blob == before_blob:
            continue
        if after_blob is None or before_blob is None:
            # The dune file itself appeared or disappeared.
            return True
        after_text = _blob_text(after_blob, owner, repo)
        before_text = _blob_text(before_blob, owner, repo)
        if after_text is None or before_text is None:
            return None
        if dune_dependency_forms(after_text) != dune_dependency_forms(before_text):
            return True
    return False


def check_pr_axis_stale(
    pr_number: int,
    owner: str,
    repo: str,
    hours: int = 24,
    limit: int = 20,
) -> List[AxisRisk]:
    """Check if an open PR is at risk of being stale from recent merges."""
    pr_base_sha, pr_base_ref = get_pr_base_info(pr_number, owner, repo)
    if not pr_base_ref:
        print(f"Could not determine base ref for PR #{pr_number}.", file=sys.stderr)
        sys.exit(2)

    open_files = get_pr_files(pr_number, owner, repo)
    if not open_files:
        print(f"Warning: no files found for PR #{pr_number}", file=sys.stderr)
        return []

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

        # Staleness is scoped per base branch: a default-branch PR compares
        # against default-branch merges, a stacked PR against sibling merges
        # into the same parent branch (the #25063/#25044 incident class).
        if not merged_pr_in_scope(pr_base_ref, merged.get("baseRefName")):
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
            # A restacked parent gives the same delta new SHAs, so ancestry
            # says absent while the content is already there (#29377).
            if merge_commit and merged_delta_is_present_in_base(
                merged_files, merge_commit, pr_base_sha, owner, repo
            ):
                print(
                    f"axis: #{merged_num} delta already present in base "
                    f"{pr_base_sha[:12]} by content; skipping overlap analysis",
                    file=sys.stderr,
                )
                continue

        # Determine risk type and confidence
        confidence = "LOW"
        risk_type = "FILE_OVERLAP"

        # A shared dune file only breaks a dependent build when the merged PR
        # actually changed what it links. Comparing the (libraries ...) stanzas
        # across the merge is the property BUILD_DEP_BREAK names; the file's
        # name is not (#29359 R11).
        dune_overlap = {f for f in overlap if f.endswith("/dune") or f == "dune"}
        if dune_overlap:
            merge_commit = (merged.get("mergeCommit") or {}).get("oid")
            parents = ((merged.get("mergeCommit") or {}).get("parents") or {}).get(
                "nodes"
            ) or []
            parent_sha = parents[0].get("oid") if parents else None
            deps_changed: Optional[bool] = None
            if merge_commit and parent_sha:
                deps_changed = dune_deps_changed(
                    dune_overlap, merge_commit, parent_sha, owner, repo
                )
            if deps_changed is not False:
                risk_type = "BUILD_DEP_BREAK"
                confidence = "HIGH"
                if deps_changed is None:
                    print(
                        f"axis: #{merged_num} dune dependency stanzas unreadable; "
                        f"keeping BUILD_DEP_BREAK unverified",
                        file=sys.stderr,
                    )

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

    assert merged_pr_in_scope("trunk", "trunk"), "same-base merge is in scope"
    assert not merged_pr_in_scope("trunk", "stack-parent"), (
        "merge into another branch is out of scope for a trunk PR"
    )
    assert merged_pr_in_scope("stack-parent", "stack-parent"), (
        "sibling merge into the same parent branch is in scope for a stacked PR"
    )
    assert not merged_pr_in_scope("stack-parent", "trunk"), (
        "trunk merge is out of scope for a stacked PR (parent PR owns it)"
    )
    assert merged_pr_in_scope(None, "trunk"), "missing base ref stays in scope"
    print("self-test: per-base staleness scope incl. stacked siblings (PASS)")

    # Content containment (#29377). Seed the tree cache so the cases stay
    # offline; a restack rewrites SHAs but leaves the same blobs behind.
    saved_cache = dict(_TREE_BLOBS_CACHE)
    try:
        _TREE_BLOBS_CACHE.clear()
        _TREE_BLOBS_CACHE["merge-sha"] = {"lib/dune": "blob-a", "lib/x.ml": "blob-b"}
        _TREE_BLOBS_CACHE["restacked-base"] = {
            "lib/dune": "blob-a",
            "lib/x.ml": "blob-b",
            "lib/unrelated.ml": "blob-c",
        }
        _TREE_BLOBS_CACHE["diverged-base"] = {
            "lib/dune": "blob-a",
            "lib/x.ml": "blob-z",
        }
        _TREE_BLOBS_CACHE["deleted-base"] = {"lib/dune": "blob-a"}
        _TREE_BLOBS_CACHE["truncated"] = None
        touched = {"lib/dune", "lib/x.ml"}

        assert merged_delta_is_present_in_base(
            touched, "merge-sha", "restacked-base", "o", "r"
        ), "a restacked base carrying the same blobs contains the delta"
        assert not merged_delta_is_present_in_base(
            touched, "merge-sha", "diverged-base", "o", "r"
        ), "a base that changed a touched file must fall through to overlap analysis"
        assert not merged_delta_is_present_in_base(
            touched, "merge-sha", "truncated", "o", "r"
        ), "a truncated tree proves nothing"
        assert not merged_delta_is_present_in_base(
            set(), "merge-sha", "restacked-base", "o", "r"
        ), "an empty file set proves nothing"
        assert merged_delta_is_present_in_base(
            {"lib/x.ml"}, "deleted-base", "deleted-base", "o", "r"
        ), "a path missing from both trees is a merged deletion, not a difference"
        print("self-test: restacked delta recognised by content (PASS)")
    finally:
        _TREE_BLOBS_CACHE.clear()
        _TREE_BLOBS_CACHE.update(saved_cache)

    # BUILD_DEP_BREAK is a claim about dependency stanzas (#29359 R11). The
    # parser is pure, so every case below is exact and offline.
    base_dune = """
(library
 (name masc)
 (libraries eio yojson (re_export uri))
 (preprocess (pps ppx_deriving.show)))
"""
    # The comment sits *inside* the stanza: a parser that does not strip it
    # carries the prose into the compared text and reports a false change.
    commented = """
; a note about the library
(library
 (name masc)

 (libraries eio ; the effects runtime
            yojson
            (re_export uri))
 (preprocess (pps ppx_deriving.show)))
"""
    assert dune_dependency_forms(base_dune) == dune_dependency_forms(commented), (
        "comments and blank lines are not dependency changes"
    )
    print("self-test: dune comment/whitespace edit is not a dep change (PASS)")

    added = base_dune.replace("(libraries eio yojson", "(libraries eio yojson digestif")
    assert dune_dependency_forms(added) != dune_dependency_forms(base_dune), (
        "a new library is a dependency change"
    )
    renamed = base_dune.replace("(name masc)", "(name masc_core)")
    assert dune_dependency_forms(renamed) == dune_dependency_forms(base_dune), (
        "renaming the library does not change what it links"
    )
    ppx = base_dune.replace("ppx_deriving.show", "ppx_deriving.eq")
    assert dune_dependency_forms(ppx) != dune_dependency_forms(base_dune), (
        "a ppx swap is a dependency change"
    )
    print("self-test: added library and ppx swap detected, rename ignored (PASS)")

    # The `;` lives inside a string *inside* the stanza. Treating it as a
    # comment eats the closing parens, so the form never balances and vanishes.
    quoted = base_dune.replace(
        "(pps ppx_deriving.show)", '(pps ppx_deriving.show -flag "a;b")'
    )
    quoted_forms = dune_dependency_forms(quoted)
    assert len(quoted_forms) == len(dune_dependency_forms(base_dune)), (
        "a semicolon inside a string literal must not end the stanza"
    )
    assert any('"a;b"' in form for form in quoted_forms), (
        "the quoted flag belongs in the compared text"
    )
    print("self-test: `;` inside a string literal is not a comment (PASS)")

    # dune_deps_changed over seeded trees/blobs: the same three cases the
    # parser answers, now through the lookup the live path uses.
    saved_tree = dict(_TREE_BLOBS_CACHE)
    saved_blob = dict(_BLOB_TEXT_CACHE)
    try:
        _TREE_BLOBS_CACHE.clear()
        _BLOB_TEXT_CACHE.clear()
        _TREE_BLOBS_CACHE["after-comment"] = {"lib/dune": "blob-commented"}
        _TREE_BLOBS_CACHE["after-added"] = {"lib/dune": "blob-added"}
        _TREE_BLOBS_CACHE["before"] = {"lib/dune": "blob-base"}
        _TREE_BLOBS_CACHE["unreadable"] = None
        _BLOB_TEXT_CACHE["blob-base"] = base_dune
        _BLOB_TEXT_CACHE["blob-commented"] = commented
        _BLOB_TEXT_CACHE["blob-added"] = added

        assert (
            dune_deps_changed({"lib/dune"}, "after-comment", "before", "o", "r")
            is False
        ), "a comment-only dune edit is not a BUILD_DEP_BREAK"
        assert (
            dune_deps_changed({"lib/dune"}, "after-added", "before", "o", "r") is True
        ), "an added library is a BUILD_DEP_BREAK"
        assert (
            dune_deps_changed({"lib/dune"}, "unreadable", "before", "o", "r") is None
        ), "an unreachable tree is unknown, never a silent False"
        assert dune_deps_changed({"lib/dune"}, "before", "before", "o", "r") is False, (
            "an identical blob needs no content fetch"
        )
        print("self-test: dune dep verdict incl. unknown-is-not-false (PASS)")
    finally:
        _TREE_BLOBS_CACHE.clear()
        _TREE_BLOBS_CACHE.update(saved_tree)
        _BLOB_TEXT_CACHE.clear()
        _BLOB_TEXT_CACHE.update(saved_blob)

    print("pr_axis_check self-test: all structural cases passed")
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
