"""Immutable combined-tree evidence for the opt-in batch review path.

The reviewed ROLL is published in one squash. Member checks, verdicts and
approvals remain separate gates; no untested member prefix is published.
Git merge-tree/commit-tree create objects, never edit a checkout or branch.
"""
from dataclasses import dataclass
from enum import IntEnum
import os
import argparse
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys


class ExitCode(IntEnum):
    SUCCESS = 0
    INFRASTRUCTURE = 1
    INVALID = 2
    ROLL = 3
    LANDING = 4
    MAIN_OVERLAP = 5
    MEMBER = 6
    PENDING = 7


# Exact internal reasons, not substring or log-text classification. Shared
# run/check readers attach their ROLL/member role at the refusal boundary.
REASON_CODES = {
    **dict.fromkeys(("batch_roll_pr_identity_unavailable", "batch_roll_review_refuses_evidence"), ExitCode.ROLL),
    **dict.fromkeys(("batch_roll_tree_does_not_match_members", "batch_roll_landing_is_not_a_squash",
                    "batch_roll_landing_tree_mismatch", "batch_roll_merge_not_in_main_history",
                    "batch_final_landing_tree_mismatch", "batch_main_changed_at_merge_write"), ExitCode.LANDING),
    "batch_nonmember_main_change_invalidates_roll": ExitCode.MAIN_OVERLAP,
    **dict.fromkeys(("candidate_not_in_batch", "batch_member_without_current_pass",
                    "pr_state_or_head_changed", "pr_check_run_unavailable",
                    "not_successful_exact_head_pr_check", "run_names_another_branch",
                    "run_names_another_pr", "run_suite_not_linked_to_candidate",
                    "batch_member_has_open_change_request", "batch_member_head_or_base_changed",
                    "batch_member_verdict_names_another_run", "batch_member_no_longer_open",
                    "batch_landing_requires_roll", "batch_roll_already_merged", "batch_roll_not_yet_merged",
                    "batch_member_moved_during_check", "batch_publication_changed_during_check",
                    "batch_member_verdict_changed_during_check"), ExitCode.MEMBER),
    **dict.fromkeys(("batch_roll_pr_is_a_member", "batch_roll_has_no_changes",
                    "batch_roll_or_main_moved_during_check"), ExitCode.INVALID),
}


def refuse(f, reason, code):
    # Keep Unavailable and its existing wire reason compatible with freshness
    # callers while carrying the typed CLI outcome instead of losing context.
    error = f.Unavailable(reason)
    error.batch_exit_code = code
    raise error


def failure_code(error):
    code = getattr(error, "batch_exit_code", None)
    if isinstance(code, ExitCode):
        return code
    return REASON_CODES.get(str(error), ExitCode.INFRASTRUCTURE)


def guard_check(f, args, failure):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode:
        # Existing read-only guards distinguish refusal (2) from API/infra
        # errors (1). Do not mislabel unavailable GitHub evidence as red CI.
        refuse(f, "evidence_read_failed",
               failure if result.returncode == 2 else ExitCode.INFRASTRUCTURE)
    return result.stdout


def merge_guard(f, args):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode:
        # Batch freshness supplies 3..6 through the shell guards. Their
        # ordinary refusal remains 2; these generated arguments are already
        # validated, so that refusal concerns the member's live admission.
        if result.returncode in (3, 4, 5, 6):
            code = ExitCode(result.returncode)
        elif result.returncode == 2:
            code = ExitCode.MEMBER
        else:
            code = ExitCode.INFRASTRUCTURE
        refuse(f, "evidence_read_failed", code)


@dataclass(frozen=True)
class Member:
    pr: int
    head: str


@dataclass(frozen=True)
class Batch:
    roll: str
    base: str
    run: int
    members: tuple[Member, ...]
    keeper: str
    line: str


def parse(line):
    """Parse the RFC's complete wire grammar; no inferred/default identities."""
    value = line.removesuffix("\n")
    match = re.fullmatch(
        r"batch: PASS landing: ROLL roll: ([0-9a-f]{40}) base: ([0-9a-f]{40}) "
        r"run: ([1-9][0-9]*) members: "
        r"([1-9][0-9]*@[0-9a-f]{40}(?:,[1-9][0-9]*@[0-9a-f]{40})*) "
        r"by: ([A-Za-z0-9._-]+)", value)
    if not match:
        raise ValueError("invalid_batch_line")
    roll, base, run, members, keeper = match.groups()
    members = tuple(Member(int(pr), head) for pr, head in
                    (item.split("@") for item in members.split(",")))
    if len({member.pr for member in members}) != len(members):
        raise ValueError("duplicate_batch_member")
    if roll == base or roll in {member.head for member in members}:
        raise ValueError("batch_roll_is_not_a_combined_commit")
    return Batch(roll, base, int(run), members, keeper, value)


class Trees:
    def __init__(self, freshness, git_dir):
        self.f = freshness
        self.git = ["git", "-C", git_dir]

    def read(self, *args):
        return self.f.command(self.git + list(args)).strip()

    def ensure(self, commit):
        self.f.sha(commit)
        present = subprocess.run(self.git + ["cat-file", "-e", commit + "^{commit}"],
                                 capture_output=True)
        if present.returncode:
            self.read("fetch", "--quiet", "--no-tags", "origin", commit)

    def tree(self, commit):
        return self.read("rev-parse", commit + "^{tree}")

    def paths(self, before, after, *, removed=False):
        args = ["diff", "--name-only", "--no-renames", "-z"]
        if removed:
            args.append("--diff-filter=DT")
        # Do not strip whitespace: Git pathnames may contain it.
        return set(self.f.command(self.git + args + [before, after]).split("\0")) - {""}

    def merge(self, left, right):
        result = subprocess.run(self.git + ["merge-tree", "--write-tree", left, right],
                                text=True, capture_output=True)
        if result.returncode:
            refuse(self.f, "batch_tree_merge_conflict_or_unavailable",
                   ExitCode.LANDING if result.returncode == 1 else ExitCode.INFRASTRUCTURE)
        tree = self.f.sha(result.stdout.splitlines()[0])
        # Fixed metadata makes the synthetic graph reproducible. These objects
        # are only inputs to subsequent tree recomputation, never published.
        result = subprocess.run(self.git + ["-c", "user.name=Batch evidence",
            "-c", "user.email=batch-evidence@example.invalid", "-c", "commit.gpgSign=false",
            "commit-tree", tree, "-p", left, "-p", right],
            input="Batch evidence tree\n", text=True, capture_output=True,
            env=os.environ | {
                "GIT_AUTHOR_DATE": "2000-01-01T00:00:00Z",
                "GIT_COMMITTER_DATE": "2000-01-01T00:00:00Z"})
        if result.returncode:
            raise self.f.Unavailable("batch_tree_commit_unavailable")
        return self.f.sha(result.stdout.strip())


def trusted_line(f, gh, prefix, pr, batch, *, failure=ExitCode.MEMBER):
    rows = [row for page in f.api_pages(
        gh, f"{prefix}/issues/{pr}/comments?per_page=100") for row in page]
    matches = [row for row in rows
               if batch.line in row.get("body", "").splitlines()
               and row.get("author_association") in {"OWNER", "MEMBER", "COLLABORATOR"}
               and row.get("user", {}).get("login") != batch.keeper]
    if not matches:
        refuse(f, "batch_line_not_published_by_trusted_participant", failure)
    return tuple(sorted((row["id"], row["body"], row["author_association"]) for row in matches))


def current_checks(f, gh, repo, pr, head, git_dir, *, failure=ExitCode.MEMBER):
    """Use the very same live workflow/check gate as ordinary approval."""
    checks = Path(__file__).with_name("ci-checks.sh")
    guard_check(f, ["bash", "-c",
        'GH="$1"; repo="$2"; pr="$3"; head="$4"; gitdir="$5"; '
        'source "$6"; check_current_ci',
        "batch-checks", gh, repo, str(pr), head, git_dir, str(checks)], failure)


def decision(f, gh, repo, member):
    reader = Path(__file__).with_name("review-verdict.sh")
    return f.command(["bash", "-c",
        'GH="$1"; repo="$2"; source "$3"; verdict_for "$4" "$5"',
        "batch-verdict", gh, repo, str(reader), str(member.pr), member.head]).split()


def verdict(f, gh, repo, member):
    value = decision(f, gh, repo, member)
    if len(value) != 3 or value[0] != "PASS" or not value[1].isdecimal():
        raise f.Unavailable("batch_member_without_current_pass")
    return int(value[1])


def roll_review_state(f, gh, repo, member, run, *, required=False):
    value = decision(f, gh, repo, member)
    if (required or value) and (len(value) != 3 or value[0] != "PASS" or value[1] != str(run)):
        raise f.Unavailable("batch_roll_review_refuses_evidence")
    review_state(f, gh, "repos/" + repo, member, failure=ExitCode.ROLL)


def review_state(f, gh, prefix, member, *, failure=ExitCode.MEMBER):
    rows = [row for page in f.api_pages(
        gh, f"{prefix}/pulls/{member.pr}/reviews?per_page=100") for row in page]
    latest = {}
    for row in sorted(rows, key=lambda row: row["id"]):
        if row["state"] in {"APPROVED", "CHANGES_REQUESTED", "DISMISSED"}:
            latest[row["user"]["login"]] = row
    if any(row["state"] == "CHANGES_REQUESTED" for row in latest.values()):
        refuse(f, "batch_member_has_open_change_request", failure)


def exact_run(f, gh, prefix, pr, head, branch, run_id, *, failure=ExitCode.MEMBER):
    run = f.api(gh, f"{prefix}/actions/runs/{run_id}")
    try:
        current = f.current_pr_check(gh, prefix, head, pr, branch)
    except f.Unavailable as error:
        if str(error) == "pr_check_run_unavailable":
            refuse(f, str(error), failure)
        raise
    if (run["id"] != run_id or run["head_sha"] != head
            or run["event"] != "pull_request" or run["path"] != ".github/workflows/pr-check.yml"
            or run["status"] != "completed" or run["conclusion"] != "success"
            or not f.run_names_candidate(run, pr, branch)
            or current != run_id):
        refuse(f, "batch_run_not_current_successful_exact_pr_check", failure)
    if not run["pull_requests"]:
        suite = f.api(gh, f"{prefix}/check-suites/{run['check_suite_id']}")
        if (suite["head_sha"] != head or suite.get("head_branch") != branch
                or [row.get("number") for row in suite.get("pull_requests", [])] != [pr]):
            refuse(f, "batch_run_suite_not_linked_to_pr", failure)
    jobs = [job for page in f.api_pages(
        gh, f"{prefix}/actions/runs/{run_id}/jobs?per_page=100") for job in page["jobs"]]
    required = {"lint suite", "dune build @check", "dune build --profile release @check",
                "dashboard typecheck", "TLA model check"}
    latest = {}
    for job in sorted(jobs, key=lambda job: job["id"]):
        latest[job["name"]] = job
    if not required <= latest.keys() or any(
            latest[name]["status"] != "completed" or latest[name]["conclusion"] != "success"
            for name in required):
        refuse(f, "batch_required_jobs_not_all_successful", failure)
    return run


def resolve_roll(f, gh, repo, batch):
    prefix = "repos/" + repo
    run = f.api(gh, f"{prefix}/actions/runs/{batch.run}")
    associations = run["pull_requests"]
    if not associations:
        associations = f.api(gh, f"{prefix}/check-suites/{run['check_suite_id']}")["pull_requests"]
    matches = []
    for row in associations:
        pull = f.api(gh, f"{prefix}/pulls/{row['number']}")
        if (not pull["draft"] and pull["base"]["ref"] == "main"
                and pull["head"]["sha"] == batch.roll and pull["head"]["ref"] == run["head_branch"]
                and ((pull["state"] == "open" and not pull.get("merged"))
                     or (pull["state"] == "closed" and pull.get("merged")))):
            matches.append((Member(row["number"], batch.roll), pull))
    if len(matches) != 1:
        raise f.Unavailable("batch_roll_pr_identity_unavailable")
    roll, pull = matches[0]
    if roll.pr in {member.pr for member in batch.members}:
        raise f.Unavailable("batch_roll_pr_is_a_member")
    return roll, pull


def approvals(f, gh, repo, git_dir, members):
    guard = Path(__file__).with_name("approve-guard.sh")
    receipts = []
    for member in members:
        raw = guard_check(f, ["bash", str(guard), "--merge-check", "--receipt-json", "--repo", repo,
                             "--pr", str(member.pr), "--head", member.head, "--git-dir", git_dir], ExitCode.MEMBER)
        try:
            receipt = json.loads(raw)
            if (receipt["pr"] != member.pr or receipt["head"] != member.head
                    or not receipt["approval_ids"]
                    or any(type(value) is not int or value <= 0 for value in receipt["approval_ids"])):
                raise ValueError("invalid approval receipt")
        except (ValueError, KeyError, TypeError):
            raise f.Unavailable("invalid_approval_receipt")
        receipts.append(receipt)
    return receipts


def same_pull(before, after):
    return (all(after.get(key) == before.get(key)
                for key in ("state", "draft", "merged", "merge_commit_sha"))
            and after["head"]["sha"] == before["head"]["sha"]
            and after["head"]["ref"] == before["head"]["ref"]
            and after["base"]["ref"] == before["base"]["ref"])


def evaluate(f, *, line, repo, pr, head, run, git_dir, gh, landing=False, expected_main=None):
    batch = parse(line)
    prefix = "repos/" + repo
    roll, roll_pull = resolve_roll(f, gh, repo, batch)
    arrived = bool(roll_pull.get("merged"))
    candidate = None if pr is None and head is None and run is None else Member(pr, head)
    if candidate is not None and candidate not in (*batch.members, roll):
        raise f.Unavailable("candidate_not_in_batch")
    if landing and candidate != roll:
        raise f.Unavailable("batch_landing_requires_roll")
    if candidate is not None and arrived:
        raise f.Unavailable("batch_roll_already_merged")
    if candidate is None and not arrived:
        raise f.Unavailable("batch_roll_not_yet_merged")
    if candidate == roll and run != batch.run:
        raise f.Unavailable("batch_member_verdict_names_another_run")
    exact_run(f, gh, prefix, roll.pr, roll.head, roll_pull["head"]["ref"], batch.run, failure=ExitCode.ROLL)
    if not arrived:
        current_checks(f, gh, repo, roll.pr, roll.head, git_dir, failure=ExitCode.ROLL)
    roll_review_state(f, gh, repo, roll, batch.run, required=landing)
    published = {roll.pr: trusted_line(f, gh, prefix, roll.pr, batch, failure=ExitCode.ROLL)}
    main = f.sha(f.api(gh, f"{prefix}/commits/main")["sha"])
    trees = Trees(f, git_dir)
    for identity in (batch.base, batch.roll, main, *(member.head for member in batch.members)):
        trees.ensure(identity)

    pulls, member_runs = {}, {}
    for member in batch.members:
        pull = f.api(gh, f"{prefix}/pulls/{member.pr}")
        pulls[member.pr] = pull
        if pull["head"]["sha"] != member.head or pull["base"]["ref"] != "main" or pull["draft"]:
            raise f.Unavailable("batch_member_head_or_base_changed")
        # Original PRs are absorbed, never individually merged by this path.
        # After verified publication, a Keeper may already have closed some.
        if pull.get("merged") or (not arrived and pull["state"] != "open"):
            raise f.Unavailable("batch_member_no_longer_open")
        published[member.pr] = trusted_line(f, gh, prefix, member.pr, batch)
        cited = verdict(f, gh, repo, member)
        if member == candidate and cited != run:
            raise f.Unavailable("batch_member_verdict_names_another_run")
        exact_run(f, gh, prefix, member.pr, member.head, pull["head"]["ref"], cited)
        if not arrived:
            current_checks(f, gh, repo, member.pr, member.head, git_dir)
        review_state(f, gh, prefix, member)
        member_runs[member.pr] = cited

    reconstructed, member_paths = batch.base, set()
    for member in batch.members:
        before = reconstructed
        reconstructed = trees.merge(reconstructed, member.head)
        member_paths.update(trees.paths(before, reconstructed))
    if trees.tree(reconstructed) != trees.tree(batch.roll):
        raise f.Unavailable("batch_roll_tree_does_not_match_members")
    if not trees.paths(batch.base, batch.roll):
        raise f.Unavailable("batch_roll_has_no_changes")

    merge_commit = f.sha(roll_pull["merge_commit_sha"]) if arrived else None
    history, commit = [], main
    while commit != batch.base:
        row = trees.read("show", "--no-patch", "--format=%H %P", commit).split()
        if len(row) < 2:
            raise f.Unavailable("batch_base_not_in_available_main_history")
        history.append((commit, row[1], len(row) - 1))
        commit = row[1]
    seen, external, landing_parent = False, set(), None
    post_landing_commits = []
    for commit, parent, parent_count in reversed(history):
        if commit == merge_commit:
            if parent_count != 1:
                raise f.Unavailable("batch_roll_landing_is_not_a_squash")
            if expected_main is not None and parent != expected_main:
                raise f.Unavailable("batch_main_changed_at_merge_write")
            if trees.tree(trees.merge(parent, batch.roll)) != trees.tree(commit):
                raise f.Unavailable("batch_roll_landing_tree_mismatch")
            seen, landing_parent = True, parent
        elif seen:
            # Later main work does not invalidate an already proven historical
            # landing. Keep it observable, but never test it as pre-write input.
            post_landing_commits.append(commit)
        else:
            touched = trees.paths(parent, commit)
            removed = trees.paths(parent, commit, removed=True)
            if touched & member_paths or any(f.shared_check_input(
                    path, member_paths, reference_target_removed=path in removed) for path in touched):
                raise f.Unavailable("batch_nonmember_main_change_invalidates_roll")
            external.update(touched)
    if arrived and not seen:
        raise f.Unavailable("batch_roll_merge_not_in_main_history")
    final = merge_commit if arrived else trees.merge(main, batch.roll)
    if (trees.paths(batch.roll, final) - external
            or (not arrived and trees.paths(main, final) & external)):
        raise f.Unavailable("batch_final_landing_tree_mismatch")

    # Finish expensive CI reads before final identity/decision snapshots.
    for member in batch.members:
        exact_run(f, gh, prefix, member.pr, member.head,
                  pulls[member.pr]["head"]["ref"], member_runs[member.pr])
        if not arrived:
            current_checks(f, gh, repo, member.pr, member.head, git_dir)
    exact_run(f, gh, prefix, roll.pr, roll.head, roll_pull["head"]["ref"], batch.run, failure=ExitCode.ROLL)
    if not arrived:
        current_checks(f, gh, repo, roll.pr, roll.head, git_dir, failure=ExitCode.ROLL)
    for member in batch.members:
        end = f.api(gh, f"{prefix}/pulls/{member.pr}")
        if not same_pull(pulls[member.pr], end):
            raise f.Unavailable("batch_member_moved_during_check")
        if trusted_line(f, gh, prefix, member.pr, batch) != published[member.pr]:
            raise f.Unavailable("batch_publication_changed_during_check")
        if verdict(f, gh, repo, member) != member_runs[member.pr]:
            raise f.Unavailable("batch_member_verdict_changed_during_check")
        review_state(f, gh, prefix, member)
    end_roll = f.api(gh, f"{prefix}/pulls/{roll.pr}")
    roll_review_state(f, gh, repo, roll, batch.run, required=landing)
    if (not same_pull(roll_pull, end_roll)
            or trusted_line(f, gh, prefix, roll.pr, batch, failure=ExitCode.ROLL) != published[roll.pr]
            or f.sha(f.api(gh, f"{prefix}/commits/main")["sha"]) != main):
        raise f.Unavailable("batch_roll_or_main_moved_during_check")
    approval_receipts = None
    if landing:
        # Final admission boundary: check every bound approval AFTER all
        # expensive evidence and mutable decision reads. DISMISSED is not an
        # approval. Separate GitHub reads still cannot provide atomic CAS.
        approval_receipts = approvals(f, gh, repo, git_dir, (*batch.members, roll))
    result = {"status": "published" if arrived else "fresh", "kind": "batch", "head": head,
              "run": run, "main": main, "base": batch.base, "roll": batch.roll,
              "roll_pr": roll.pr, "roll_run": batch.run,
              "members": [{"pr": member.pr, "head": member.head, "run": member_runs[member.pr]}
                          for member in batch.members],
              "tree": trees.tree(final), "external_paths": sorted(external),
              "overlap": [], "dependencies": [], "commits": []}
    if approval_receipts is not None:
        result["approval_observation"] = approval_receipts
    if arrived:
        result.update(merge_commit=merge_commit, landing_parent=landing_parent,
                      post_landing_commits=post_landing_commits,
                      historical_approval_mapping="unavailable_without_saved_preflight_receipt",
                      absorption_candidates=[member.pr for member in batch.members
                                             if pulls[member.pr]["state"] == "open"])
    return result


def land(f, *, batch_file, repo, git_dir, gh, check_only):
    """Keeper entry: publish the tested ROLL once, then prove its arrival.

    An asynchronous merge still pending after one read returns pending. Resume
    at the next work boundary; never poll or close original PRs here.
    """
    import tempfile
    batch = parse(Path(batch_file).read_text())
    roll, pull = resolve_roll(f, gh, repo, batch)
    if pull.get("merged"):
        return evaluate(f, line=batch.line, repo=repo, pr=None, head=None, run=None,
                        git_dir=git_dir, gh=gh)
    before = evaluate(f, line=batch.line, repo=repo, pr=roll.pr, head=roll.head,
                      run=batch.run, git_dir=git_dir, gh=gh, landing=True)
    observation = {"scope": "preflight_before_merge_guard_not_write_boundary",
                   "members": before["members"], "roll": batch.roll, "roll_run": batch.run,
                   "approvals": before["approval_observation"]}
    if check_only:
        return {"status": "checked", "roll": batch.roll, "roll_pr": roll.pr,
                "members": [member.pr for member in batch.members],
                "preflight_observation": observation}
    with tempfile.TemporaryDirectory(prefix="masc-batch-evidence-") as tmp:
        frozen = Path(tmp) / "batch.txt"
        frozen.write_text(batch.line + "\n")
        merge_guard(f, ["bash", str(Path(__file__).with_name("merge-guard.sh")),
                       "--repo", repo, "--pr", str(roll.pr), "--head", roll.head,
                       "--run", str(batch.run), "--git-dir", git_dir, "--batch", str(frozen)])
    pull = f.api(gh, f"repos/{repo}/pulls/{roll.pr}")
    if not pull.get("merged"):
        return {"status": "pending", "pr": roll.pr, "head": roll.head, "roll": batch.roll,
                "preflight_observation": observation,
                "message": "merge submitted; resume at next work boundary"}
    result = evaluate(f, line=batch.line, repo=repo, pr=None, head=None, run=None,
                      git_dir=git_dir, gh=gh, expected_main=before["main"])
    result["preflight_observation"] = observation
    return result


def main():
    parser = argparse.ArgumentParser(description=land.__doc__)
    for name in ("repo", "batch", "git-dir"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location("ci_freshness", Path(__file__).with_name("ci-freshness.py"))
    f = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = f
    spec.loader.exec_module(f)
    try:
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo):
            raise ValueError("invalid_repository")
        result = land(f, batch_file=args.batch, repo=args.repo, git_dir=args.git_dir,
                      gh=os.environ.get("GUARD_GH", "gh"), check_only=args.check_only)
        code = {"published": ExitCode.SUCCESS, "checked": ExitCode.SUCCESS,
                "pending": ExitCode.PENDING}.get(result["status"], ExitCode.INVALID)
    except f.Unavailable as error:
        result = {"status": "unavailable", "reason": str(error)}
        code = failure_code(error)
    except (ValueError, KeyError, TypeError) as error:
        result = {"status": "unavailable", "reason": "invalid_evidence"}
        code = ExitCode.INVALID
    except OSError:
        result = {"status": "unavailable", "reason": "evidence_read_failed"}
        code = ExitCode.INFRASTRUCTURE
    print(json.dumps(result, sort_keys=True))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
