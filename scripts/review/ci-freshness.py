#!/usr/bin/env python3
"""Read-only, fail-closed CI provenance/freshness gate shared by review tools.

The constitution requires a new run after *any* main overlap, including Dune
includes. A clean text merge is not compiled evidence. Git reads use immutable
SHAs from GitHub; neither the worktree nor its branches are changed.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import PurePosixPath
import re
import subprocess


class Unavailable(Exception):
    pass


def command(args):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode:
        # Do not echo arbitrary GitHub/git stderr (credentials/remote URLs).
        raise Unavailable("evidence_read_failed")
    return result.stdout


def api_pages(gh, endpoint):
    raw = command([gh, "api", "--paginate", endpoint])
    decoder, pages = json.JSONDecoder(), []
    while raw.strip():
        value, end = decoder.raw_decode(raw.lstrip())
        pages.append(value)
        raw = raw.lstrip()[end:]
    if not pages:
        raise Unavailable("empty_api_response")
    return pages


def api(gh, endpoint):
    pages = api_pages(gh, endpoint)
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


def shared_check_input(path):
    # pr-check.yml builds OCaml in check/release-check for EVERY ready PR.
    # Candidate language therefore cannot narrow these build inputs. Dune
    # evaluates stanzas at every depth, so any dune file or include counts;
    # only the project files stay root-scoped. Product sources (.ml/.mli)
    # stay overlap-scoped: content, not configuration.
    p = PurePosixPath(path)
    if (path in {"masc.opam.locked", "dune-project", "dune-workspace",
                 "sandbox-images/base/Dockerfile"}
            or p.name == "dune" or p.suffix == ".inc"
            or (len(p.parts) == 1 and p.suffix == ".opam")):
        return True
    # The dashboard-types job unconditionally runs a frozen install, a
    # typecheck, and a preview build for every ready PR. Those steps read the
    # manifests, the lockfiles, and the TS/vite/vitest configs; dashboard
    # sources and assets stay overlap-scoped like any other product code.
    # Vite's config imports implementation from dashboard/dev/. Conservatively
    # include that directory's helpers instead of guessing the import graph;
    # dashboard/src/ remains ordinary product source.
    if path.startswith("dashboard/dev/"):
        return True
    if (len(p.parts) == 2 and p.parts[0] == "dashboard"
            and (p.name in {"package.json", "pnpm-lock.yaml",
                            "pnpm-workspace.yaml", "vite.config.ts",
                            "vite.preview.config.ts", "vitest.config.ts",
                            "vitest-setup.ts"}
                 or p.name == "tsconfig.json"
                 or (p.name.startswith("tsconfig.") and p.suffix == ".json"))):
        return True
    # The canonical lint driver is executable shell, not a declarative registry:
    # run-lint-suite -> audit-hardcoding-truth -> anti-fake-audit, for example,
    # also reads scripts/lint baselines. Conservatively share ALL scripts/ and
    # .github/ files, including helpers/data and future checker names.
    # This intentionally refreshes after unrelated operational-script changes;
    # a partial list or text extraction of shell calls could silently miss a
    # mandatory implementation. Test scripts also implement unconditional lints.
    return (path.startswith(("scripts/", ".github/"))
            or (path.startswith("test/") and p.suffix in {".py", ".sh", ".cjs", ".mjs"})
            or path == "connectors/browser/install-stagehand-extension.sh")


def run_names_candidate(run, pr, branch):
    # SHA equality alone does not identify a PR: two branch refs can point at
    # the same commit, and GitHub can associate a run with both PRs. Keep the
    # event branch identity as well as the PR association. Empty associations
    # still require the suite/check linkage below before granting freshness.
    return (run["head_branch"] == branch
            and (not run["pull_requests"]
                 or any(row["number"] == pr for row in run["pull_requests"])))


def current_pr_check(gh, prefix, head, pr, branch):
    runs = [run for page in api_pages(
        gh, f"{prefix}/actions/runs?head_sha={head}&event=pull_request&per_page=100")
        for run in page["workflow_runs"]
        if run["head_sha"] == head and run["event"] == "pull_request"
        and run["path"] == ".github/workflows/pr-check.yml"
        and run["conclusion"] != "cancelled"
        and run_names_candidate(run, pr, branch)]
    if not runs:
        raise Unavailable("pr_check_run_unavailable")
    # Same-head cancelled concurrency twins do not replace a real observation.
    # A newer queued/failed/skipped run DOES replace an older success; evaluate
    # below refuses it instead of asking a reviewer to certify stale evidence.
    return max(runs, key=lambda run: (run["run_number"], run["id"]))["id"]


def evaluate(*, repo, pr, head, run, git_dir, gh):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise Unavailable("invalid_repository")
    sha(head)
    if pr <= 0 or (run is not None and run <= 0):
        raise Unavailable("invalid_pr_or_run")
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
        if not any(row["number"] == pr for row in associations):
            raise Unavailable("run_names_another_pr")
    else:
        # Associations can disappear after branch/PR lifecycle changes. Bind
        # the run's suite to the live candidate's check-runs and branch instead.
        # Association head/base objects are mutable, NOT historical checkout IDs.
        suite_id = evidence["check_suite_id"]
        suite = api(gh, f"{prefix}/check-suites/{suite_id}")
        checks = [check for page in api_pages(gh, f"{prefix}/commits/{head}/check-runs?per_page=100")
                  for check in page["check_runs"]]
        if (suite["head_sha"] != head or evidence["head_branch"] != current["head"]["ref"]
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
    main = sha(api(gh, f"{prefix}/commits/main")["sha"])
    git = ["git", "-C", git_dir]
    for identity in (main, head):
        present = subprocess.run(git + ["cat-file", "-e", identity + "^{commit}"], capture_output=True)
        if present.returncode:
            command(git + ["fetch", "--quiet", "--no-tags", "origin", identity])
    changed, commits = set(), []
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
        overlap = sorted(touched & paths)
        dependencies = sorted(p for p in touched if shared_check_input(p))
        changed.update(touched)
        if overlap or dependencies:
            commits.append({"sha": commit, "committed_at": datetime.fromtimestamp(
                int(epoch), timezone.utc).isoformat(), "overlap": overlap,
                "dependencies": dependencies,
                "reason": "post_run_overlap" if after_run else "graph_overlap_unverified_tested_base"})
        commit = parents[0]
    comparison_ancestor = commit
    # Observations are pinned to one main/head pair; moving targets refuse.
    end = api(gh, f"{prefix}/pulls/{pr}")
    end_main = sha(api(gh, f"{prefix}/commits/main")["sha"])
    if (end["state"] != "open" or end["head"]["sha"] != head
            or end["base"]["ref"] != "main" or end["draft"]
            or end.get("merged") or end_main != main):
        raise Unavailable("pr_or_main_moved_during_check")
    overlap = sorted(paths & changed)
    dependencies = sorted(p for p in changed if shared_check_input(p))
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
    args = parser.parse_args()
    try:
        result = evaluate(repo=args.repo, pr=args.pr, head=args.head, run=args.run,
                          git_dir=args.git_dir, gh=os.environ.get("GUARD_GH", "gh"))
    except (Unavailable, ValueError, KeyError, TypeError, OSError) as error:
        result = {"status": "unavailable", "reason": str(error) if isinstance(error, Unavailable)
                  else "invalid_evidence", "head": args.head, "run": args.run}
    if args.format == "ledger":
        if result["status"] == "fresh": print("fresh\t0")
        elif result["status"] == "unavailable": print("unknown:freshness\t?")
        elif result["overlap"]: print(f"stale:{len(result['overlap'])}\t{len(result['overlap'])}")
        else: print("dependency:" + ",".join(result["dependencies"]) + "\t0")
        return 0
    print(json.dumps(result, sort_keys=True))
    return {"fresh": 0, "stale": 2, "unavailable": 1}[result["status"]]


if __name__ == "__main__":
    raise SystemExit(main())
