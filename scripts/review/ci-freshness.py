#!/usr/bin/env python3
"""Read-only, fail-closed CI provenance/freshness gate shared by review tools.

The constitution requires a new run after *any* main overlap, including Dune
includes. A clean text merge is not compiled evidence. Git reads use immutable
SHAs from GitHub; neither the worktree nor its branches are changed.
"""
import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys


class Unavailable(Exception):
    pass


class NoPrCheckRun(Unavailable):
    """No PR-check run names this head. A batch caller blames the PR it reads."""

    def __init__(self):
        super().__init__("pr_check_run_unavailable")


def command(args):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode:
        # Do not echo arbitrary GitHub/git stderr (credentials/remote URLs).
        raise Unavailable("evidence_read_failed")
    return result.stdout


def api_pages(gh, endpoint, *, paginate=True):
    args = [gh, "api"]
    if paginate:
        args.append("--paginate")
    raw = command(args + [endpoint])
    decoder, pages = json.JSONDecoder(), []
    while raw.strip():
        value, end = decoder.raw_decode(raw.lstrip())
        pages.append(value)
        raw = raw.lstrip()[end:]
    if not pages:
        raise Unavailable("empty_api_response")
    return pages


def api(gh, endpoint, *, paginate=True):
    pages = api_pages(gh, endpoint, paginate=paginate)
    if len(pages) != 1 or not isinstance(pages[0], dict):
        raise Unavailable("invalid_object_response")
    return pages[0]


def timestamp(value):
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise Unavailable("timestamp_without_timezone")
    return parsed.timestamp()


def sha(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{40}", value):
        raise Unavailable("invalid_commit_identity")
    return value


@dataclass(frozen=True)
class SharedCheckInputs:
    """An explicit path family and the required job that consumes it."""
    name: str
    consumer: str
    paths: tuple[str, ...] = ()
    trees: tuple[str, ...] = ()
    names: tuple[str, ...] = ()
    suffixes: tuple[str, ...] = ()
    script_trees: tuple[str, ...] = ()

    def contains(self, path):
        leaf = PurePosixPath(path).name
        return (path in self.paths or leaf in self.names
                or any(path.startswith(tree) for tree in self.trees)
                or any(path.endswith(suffix) for suffix in self.suffixes)
                or (any(path.startswith(tree) for tree in self.script_trees)
                    and PurePosixPath(path).suffix in {".py", ".sh", ".cjs", ".mjs"}))


# This is a bounded inventory of CI drivers and shared fixture/build inputs,
# not a dependency graph of every source inspected by a whole-tree lint.
# Unlisted paths are still checked for direct overlap below. In particular,
# unrelated prose and independently checked release fragments are not global
# dependencies merely because a required lint validates them.
SHARED_CHECK_INPUTS = (
    SharedCheckInputs(
        "ci_drivers",
        "pr-check.yml jobs and run-lint-suite.sh execute repository helpers; "
        "check-guards-are-wired.py discovers checker scripts and their baselines",
        paths=(".github/issue-taxonomy.json",),
        trees=("scripts/", ".github/workflows/", ".github/actions/")),
    SharedCheckInputs(
        "dune_and_opam",
        "pr-check.yml dev/release @check, @test/stanzas/runtest and opam dependency installation",
        names=("dune", "dune-project", "dune-workspace"),
        suffixes=(".inc", ".opam", ".opam.locked"),
        trees=("dune.lock/",)),
    SharedCheckInputs(
        "fixture_drivers_and_data",
        "pr-check.yml installer/release fixtures; run-lint-suite.sh fixture/self-test drivers; "
        "test_run_standalone_suites.py stages lib/masc_http_client; "
        "test_bench_deps_diagnosis.py sources the real deps.sh; run-edited-tests.sh "
        "reads ci-known-failures.txt; @test/stanzas/runtest reads coverage_test_names.txt",
        paths=("benchmarks/terminal_bench/driver/deps.sh", "test/ci-known-failures.txt",
               "test/stanzas/coverage_test_names.txt"),
        trees=("test/fixtures/", "lib/masc_http_client/"),
        script_trees=("test/",)),
    SharedCheckInputs(
        "required_structural_fixtures",
        "pr-check.yml builds node parity aliases from test/dune and "
        "test_browser_interaction.inc, and @packages/agent_core/test/exact-output-single-surface "
        "whose explicit deps consume provider interfaces, implementations and fixtures",
        paths=("connectors/browser/extension/background.js",
               "packages/agent_core/test/check_public_mli_callbacks.ml"),
        trees=("packages/agent_core/scripts/", "packages/agent_core/test/fixtures/",
               "packages/agent_core/lib/llm_provider/")),
    SharedCheckInputs(
        "runtime_configuration",
        "pr-check.yml installer fixtures read config/runtime.toml; @check embeds config; "
        "run-lint-suite.sh validates prompt/tool registries",
        trees=("config/",)),
    SharedCheckInputs(
        "tla_specifications",
        "run-lint-suite.sh runs check-spec-truth.sh Mirrors resolution, "
        "tla-bug-model-ratchet.sh, audit-tla-cfg-orphan.sh, "
        "audit-tla-annotation-drift.sh --check-cross-spec and "
        "check-tla-harness-coverage.sh over the specs tree",
        trees=("specs/",)),
    SharedCheckInputs(
        "dashboard_build",
        "pr-check.yml dashboard-types installs pnpm dependencies, typechecks, "
        "runs backend-coupled Vitest tests and builds vite.preview.config.ts; "
        "Vite imports dashboard/dev/source-context-plugin.ts",
        paths=("dashboard/package.json", "dashboard/pnpm-lock.yaml",
               "dashboard/pnpm-workspace.yaml", "dashboard/tsconfig.json",
               "dashboard/tsconfig.node.json", "dashboard/vite.config.ts",
               "dashboard/vite.preview.config.ts", "dashboard/vitest.config.ts",
               "dashboard/vitest-setup.ts", "dashboard/index.html",
               "dashboard/.env", "dashboard/.env.production", "dashboard/.env.development"),
        trees=("dashboard/dev/",)),
    SharedCheckInputs(
        "document_contracts",
        "pr-check.yml check-doc-truth.sh compares version/install/translation inputs "
        "and the docs/spec invariant-prefix census; test_doc_truth_stable_inputs.py "
        "runs the real checks and version bump in an isolated checkout; "
        "run-lint-suite.sh/check-issue-taxonomy-truth.sh compares CONTRIBUTING.md to its SSOT",
        paths=("CONTRIBUTING.md", "CHANGELOG.md", "README.md", "README.ko.md", "ROADMAP.md",
               "docs/INSTALL.md", "docs/INSTALL.ko.md", "docs/PRODUCT-OPERATING-PLAN.md",
               "docs/MCP-TEMPLATE.md", "docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md",
               "docs/TUI-GUIDE.md", "docs/DASHBOARD-INTEGRATION.md",
               "docs/AGENT-CORE-BOUNDARY.md", "docs/KEEPER-USER-MANUAL.md",
               "docs/RELEASE-EVIDENCE.md",
               "docs-site/src/content/docs/getting-started/quickstart.md",
               "docs-site/src/content/docs/ko/getting-started/quickstart.md",
               "quickstart.sh"),
        trees=("docs/spec/",)),
)

# changelog-fragments.py:parse_fragment/load_all/check validates each distinct
# fragment independently. pr-guard examines the candidate's own diff. The
# required version-bump fixture also folds the real fragments, so a candidate
# editing any of these consumers cannot reuse its old result after new data
# arrives. Consumer changes on main are already covered by the groups above.
FRAGMENT_CONSUMERS = frozenset({
    "scripts/changelog-fragments.py", "scripts/bump-version.sh",
    "scripts/check-doc-truth.sh", "scripts/check-version-truth.sh",
    "test/test_doc_truth_stable_inputs.py", "test/test_changelog_fragments.py",
    "scripts/ci/run-lint-suite.sh", ".github/workflows/pr-check.yml",
})


# rfc-generate-index.py:collect_entries checks uniqueness and parent relations
# across the RFC set. Two RFC-only candidates can conflict without sharing a
# filename; ordinary product changes do not alter that checked data or parser.
RFC_CONSUMERS = frozenset({
    "scripts/rfc-generate-index.py", "scripts/ci/run-lint-suite.sh",
    ".github/workflows/pr-check.yml",
})


# check-doc-truth.sh:docs_to_scan validates the existence of these documents'
# local references. A candidate can add a reference to a file that later main
# removes, although the two changed path sets are disjoint. Content-only target
# edits do not affect this existence check and remain overlap-scoped.
DOC_REFERENCE_CONSUMERS = frozenset({
    "README.md", "README.ko.md", "ROADMAP.md", "docs/PRODUCT-OPERATING-PLAN.md",
    "docs/MCP-TEMPLATE.md", "docs/TUI-GUIDE.md", "docs/spec/SPEC-INDEX.md",
    "docs/spec/00-glossary.md", "docs/spec/01-system-overview.md",
    "docs/spec/09-server-transport.md", "docs/spec/10-dashboard.md",
    "docs/KEEPER-USER-MANUAL.md", "docs/RELEASE-EVIDENCE.md",
    "scripts/check-doc-truth.sh", "test/test_doc_truth_stable_inputs.py",
    "scripts/ci/run-lint-suite.sh", ".github/workflows/pr-check.yml",
})


def doc_reference_target(path):
    """Target families accepted by check-doc-truth.sh's local reference reader."""
    p = PurePosixPath(path)
    if path.startswith("docs/"):
        return True
    if path.startswith("packages/") and p.suffix in {".md", ".mli", ".ml", ".sh", ".toml"}:
        return True
    if path.startswith(("lib/", "test/")) and p.suffix in {".ml", ".mli"}:
        return True
    if path.startswith("scripts/") and p.suffix == ".sh":
        return True
    return path in {"dune-project", "ROADMAP.md", "CHANGELOG.md"} or (
        len(p.parts) == 1 and p.suffix == ".opam")


def shared_check_input(path, pr_paths=(), *, reference_target_removed=False):
    if (reference_target_removed and doc_reference_target(path)
            and not DOC_REFERENCE_CONSUMERS.isdisjoint(pr_paths)):
        return True
    if path.startswith("changelog.d/"):
        if path == "changelog.d/README.md":
            return False  # fragment_paths explicitly ignores this guide.
        p = PurePosixPath(path)
        # The existing FRAGMENT_NAME grammar is [1-9][0-9]*.md. Only those
        # direct children have the independent per-fragment check contract;
        # unknown shapes are not granted the same exemption.
        if (len(p.parts) != 2 or p.suffix != ".md" or not p.stem.isascii()
                or not p.stem.isdecimal() or p.stem.startswith("0")):
            return True
        return not FRAGMENT_CONSUMERS.isdisjoint(pr_paths)
    if path.startswith("docs/rfc/"):
        return (not RFC_CONSUMERS.isdisjoint(pr_paths)
                or any(candidate.startswith("docs/rfc/") for candidate in pr_paths))
    return any(group.contains(path) for group in SHARED_CHECK_INPUTS)


def run_names_candidate(run, pr, branch):
    # SHA equality alone does not identify a PR: two branch refs can point at
    # the same commit, and GitHub can associate a run with both PRs. Keep the
    # event branch identity and require an unambiguous PR association. Empty associations
    # still require the suite/check linkage below before granting freshness.
    return (run["head_branch"] == branch
            and (not run["pull_requests"]
                 or [row["number"] for row in run["pull_requests"]] == [pr]))


def current_pr_check(gh, prefix, head, pr, branch):
    runs = [run for page in api_pages(
        gh, f"{prefix}/actions/runs?head_sha={head}&event=pull_request&per_page=100")
        for run in page["workflow_runs"]
        if run["head_sha"] == head and run["event"] == "pull_request"
        and run["path"] == ".github/workflows/pr-check.yml"
        and run["conclusion"] != "cancelled"
        and run_names_candidate(run, pr, branch)]
    if not runs:
        raise NoPrCheckRun()
    # Same-head cancelled concurrency twins do not replace a real observation.
    # A newer queued/failed/skipped run DOES replace an older success; evaluate
    # below refuses it instead of asking a reviewer to certify stale evidence.
    return max(runs, key=lambda run: (run["run_number"], run["id"]))["id"]


def evaluate(*, repo, pr, head, run, git_dir, gh, batch_line=None, landing=False):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise Unavailable("invalid_repository")
    sha(head)
    if pr <= 0 or (run is not None and run <= 0):
        raise Unavailable("invalid_pr_or_run")
    if landing and batch_line is None:
        raise Unavailable("landing_requires_batch")
    if batch_line is not None:
        import batch_evidence
        return batch_evidence.evaluate(sys.modules[__name__], line=batch_line,
            repo=repo, pr=pr, head=head, run=run, git_dir=git_dir, gh=gh, landing=landing)
    prefix = "repos/" + repo
    current = api(gh, f"{prefix}/pulls/{pr}")
    if (current["state"] != "open" or current["draft"] or current.get("merged")
            or current["base"]["ref"] != "main" or current["head"]["sha"] != head):
        raise Unavailable("pr_state_or_head_changed")
    if run is None:
        run = current_pr_check(gh, prefix, head, pr, current["head"]["ref"])
    evidence = api(gh, f"{prefix}/actions/runs/{run}")
    if (evidence["id"] != run or evidence["head_sha"] != head
            or evidence["event"] != "pull_request"
            or evidence["path"] != ".github/workflows/pr-check.yml"
            or evidence["status"] != "completed" or evidence["conclusion"] != "success"):
        raise Unavailable("not_successful_exact_head_pr_check")
    if evidence["head_branch"] != current["head"]["ref"]:
        raise Unavailable("run_names_another_branch")
    associations = evidence["pull_requests"]
    if associations:
        if [row["number"] for row in associations] != [pr]:
            raise Unavailable("run_names_another_pr")
    else:
        # Associations can disappear after branch/PR lifecycle changes. Bind
        # the run's suite to the live candidate's suite identity, branch and
        # check-runs instead. Association head/base objects are mutable, NOT
        # historical checkout IDs. A same-SHA suite for another same-branch PR
        # must not qualify, so an absent/foreign suite association refuses.
        suite_id = evidence["check_suite_id"]
        suite = api(gh, f"{prefix}/check-suites/{suite_id}")
        checks = [check for page in api_pages(gh, f"{prefix}/commits/{head}/check-runs?per_page=100")
                  for check in page["check_runs"]]
        if (suite["head_sha"] != head or suite.get("head_branch") != current["head"]["ref"]
                or [row.get("number") for row in suite.get("pull_requests", [])] != [pr]
                or not any(check["head_sha"] == head and check["check_suite"]["id"] == suite_id
                           for check in checks)):
            raise Unavailable("run_suite_not_linked_to_candidate")
    since = timestamp(evidence["created_at"])
    files = [row for page in api_pages(gh, f"{prefix}/pulls/{pr}/files?per_page=100")
             for row in page]
    # GitHub caps PR files at 3000. Refuse an incomplete response, never silently
    # grant freshness from a truncated path set.
    if len(files) != current["changed_files"] or not files:
        raise Unavailable("incomplete_pr_file_list")
    paths = {row["filename"] for row in files}
    paths.update(row["previous_filename"] for row in files if "previous_filename" in row)
    # Commit files can paginate, but the identity lives on the first page.
    main = sha(api(gh, f"{prefix}/commits/main", paginate=False)["sha"])
    git = ["git", "-C", git_dir]
    for identity in (main, head):
        present = subprocess.run(git + ["cat-file", "-e", identity + "^{commit}"], capture_output=True)
        if present.returncode:
            command(git + ["fetch", "--quiet", "--no-tags", "origin", identity])
    changed, reference_targets_removed, commits = set(), set(), []
    candidate_ancestors = set(command(git + ["rev-list", head]).splitlines())
    # Commit dates are not guaranteed integration dates (fast-forward/rebase).
    # Without an immutable tested-base receipt, an overlapping main commit
    # absent from the candidate also refuses, even if its date predates the run.
    # Disjoint main changes remain admissible. The required history is only
    # main's first-parent suffix down to an ancestor proven in the candidate.
    # A shallow boundary below that intersection is irrelevant; one before it
    # cannot prove coverage and refuses. Plain git log hides merge paths, so
    # explicitly diff each entry against its first parent.
    commit = main
    while commit not in candidate_ancestors:
        row = command(git + ["show", "--no-patch", "--format=%H %ct %P", commit])
        commit, epoch, *parents = row.split()
        after_run = int(epoch) >= since
        if not parents:
            raise Unavailable("required_main_history_unavailable")
        touched = set(command(git + ["diff", "--name-only", "--no-renames", "-z",
                                      parents[0], commit]).split("\0")) - {""}
        removed = set(command(git + ["diff", "--name-only", "--diff-filter=DT",
                                      "--no-renames", "-z", parents[0], commit]).split("\0")) - {""}
        overlap = sorted(touched & paths)
        dependencies = sorted(p for p in touched if shared_check_input(
            p, paths, reference_target_removed=p in removed))
        changed.update(touched)
        reference_targets_removed.update(removed)
        if overlap or dependencies:
            commits.append({"sha": commit, "committed_at": datetime.fromtimestamp(
                int(epoch), timezone.utc).isoformat(), "overlap": overlap,
                "dependencies": dependencies,
                "reason": "post_run_overlap" if after_run else "graph_overlap_unverified_tested_base"})
        commit = parents[0]
    comparison_ancestor = commit
    # Observations are pinned to one main/head pair; moving targets refuse.
    end = api(gh, f"{prefix}/pulls/{pr}")
    end_main = sha(api(gh, f"{prefix}/commits/main", paginate=False)["sha"])
    if (end["state"] != "open" or end["head"]["sha"] != head
            or end["base"]["ref"] != "main" or end["draft"]
            or end.get("merged") or end_main != main):
        raise Unavailable("pr_or_main_moved_during_check")
    overlap = sorted(paths & changed)
    dependencies = sorted(p for p in changed if shared_check_input(
        p, paths, reference_target_removed=p in reference_targets_removed))
    return {"status": "stale" if commits else "fresh", "head": head, "main": main,
            "comparison_ancestor": comparison_ancestor,
            "run": run, "created_at": evidence["created_at"], "overlap": overlap,
            "dependencies": dependencies, "commits": commits}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("repo", "head", "git-dir"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--pr", required=True, type=int)
    parser.add_argument("--run", type=int,
                        help="Cited run; omitted only for pre-review queue inspection")
    parser.add_argument("--format", choices=("json", "ledger"), default="json")
    parser.add_argument("--batch", help="File containing the published immutable batch line")
    parser.add_argument("--landing", action="store_true", help="Require the ROLL publication target and every bound approval")
    args = parser.parse_args()
    # Only --batch imports batch_evidence; the approve-guard self-test copies
    # this file without it. A batch Refusal carries its own exit code.
    batch = None
    if args.batch:
        import batch_evidence as batch
    # Errors whose message is the receipt's reason token.
    token_errors = (Unavailable,) if batch is None else (Unavailable, batch.Refusal)
    batch_code = None
    try:
        result = evaluate(repo=args.repo, pr=args.pr, head=args.head, run=args.run,
                          git_dir=args.git_dir, gh=os.environ.get("GUARD_GH", "gh"),
                          batch_line=Path(args.batch).read_text() if args.batch else None,
                          landing=args.landing)
    except (*token_errors, ValueError, KeyError, TypeError, OSError) as error:
        result = {"status": "unavailable", "reason": str(error) if isinstance(error, token_errors)
                  else "invalid_evidence", "head": args.head, "run": args.run}
        if batch is not None:
            batch_code = batch.failure_code(sys.modules[__name__], error)
    if args.format == "ledger":
        if result["status"] == "fresh": print("fresh\t0")
        elif result["status"] == "unavailable": print("unknown:freshness\t?")
        elif result["overlap"]: print(f"stale:{len(result['overlap'])}\t{len(result['overlap'])}")
        else: print("dependency:" + ",".join(result["dependencies"]) + "\t0")
        return 0
    print(json.dumps(result, sort_keys=True))
    return batch_code if batch_code is not None else {"fresh": 0, "stale": 2, "unavailable": 1}[result["status"]]


if __name__ == "__main__":
    raise SystemExit(main())
