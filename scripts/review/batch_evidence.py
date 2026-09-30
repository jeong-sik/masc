"""Immutable combined-tree evidence for the opt-in batch review path.

The reviewed ROLL is published in one squash. Each member needs a non-author
GitHub review on its current commit with a first line:
member-review: COMPLETE pr: N base: BASE40 head: HEAD40 scope: full-delta by: KEEPER
The base is the batch main base or the preceding member head for a stack.
The ROLL alone supplies integrated CI, PASS, and approval. Member CI run
numbers are never aliases for the ROLL run.
Git merge-tree/commit-tree create objects, never edit a checkout or branch.
"""
from dataclasses import dataclass
from enum import Enum, IntEnum
import os
import argparse
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import roll_input


class ExitCode(IntEnum):
    SUCCESS = 0
    INFRASTRUCTURE = 1
    INVALID = 2
    ROLL = 3
    LANDING = 4
    MAIN_OVERLAP = 5
    MEMBER = 6
    PENDING = 7


class Reason(Enum):
    """Every refusal this module raises. The value is the receipt's `reason`.

    Member names are the value without its `batch_` prefix. The exit code is
    not part of a Reason; Refusal carries the one chosen at the raise site.
    """
    # A shell guard exited non-zero. The token predates this enum; the
    # guard's exit status picks the code.
    EVIDENCE_READ_FAILED = "evidence_read_failed"
    INVALID_APPROVAL_RECEIPT = "invalid_approval_receipt"
    LINE_NOT_PUBLISHED_BY_TRUSTED_PARTICIPANT = "batch_line_not_published_by_trusted_participant"
    MEMBER_WITHOUT_CURRENT_REVIEW = "batch_member_without_current_review"
    MEMBER_HAS_LATE_FAIL = "batch_member_has_late_fail"
    ROLL_REVIEW_REFUSES_EVIDENCE = "batch_roll_review_refuses_evidence"
    MEMBER_HAS_OPEN_CHANGE_REQUEST = "batch_member_has_open_change_request"
    PR_CHECK_RUN_UNAVAILABLE = "pr_check_run_unavailable"
    RUN_NOT_CURRENT_SUCCESSFUL_EXACT_PR_CHECK = "batch_run_not_current_successful_exact_pr_check"
    RUN_SUITE_NOT_LINKED_TO_PR = "batch_run_suite_not_linked_to_pr"
    REQUIRED_JOBS_NOT_ALL_SUCCESSFUL = "batch_required_jobs_not_all_successful"
    ROLL_PR_IDENTITY_UNAVAILABLE = "batch_roll_pr_identity_unavailable"
    ROLL_PR_IS_A_MEMBER = "batch_roll_pr_is_a_member"
    CANDIDATE_NOT_IN_BATCH = "candidate_not_in_batch"
    LANDING_REQUIRES_ROLL = "batch_landing_requires_roll"
    ROLL_ALREADY_MERGED = "batch_roll_already_merged"
    ROLL_NOT_YET_MERGED = "batch_roll_not_yet_merged"
    ROLL_VERDICT_NAMES_ANOTHER_RUN = "batch_roll_verdict_names_another_run"
    MEMBER_RUN_NOT_APPLICABLE = "batch_member_run_not_applicable"
    ROLL_INPUT_MISMATCH = "batch_roll_input_mismatch"
    ROLL_RUN_RECEIPT_MISMATCH = "batch_roll_run_receipt_mismatch"
    MEMBER_HEAD_OR_BASE_CHANGED = "batch_member_head_or_base_changed"
    MEMBER_NO_LONGER_OPEN = "batch_member_no_longer_open"
    TREE_MERGE_CONFLICT_OR_UNAVAILABLE = "batch_tree_merge_conflict_or_unavailable"
    TREE_COMMIT_UNAVAILABLE = "batch_tree_commit_unavailable"
    ROLL_TREE_DOES_NOT_MATCH_MEMBERS = "batch_roll_tree_does_not_match_members"
    ROLL_HAS_NO_CHANGES = "batch_roll_has_no_changes"
    BASE_NOT_IN_AVAILABLE_MAIN_HISTORY = "batch_base_not_in_available_main_history"
    ROLL_LANDING_IS_NOT_A_SQUASH = "batch_roll_landing_is_not_a_squash"
    MAIN_CHANGED_AT_MERGE_WRITE = "batch_main_changed_at_merge_write"
    ROLL_LANDING_TREE_MISMATCH = "batch_roll_landing_tree_mismatch"
    NONMEMBER_MAIN_CHANGE_INVALIDATES_ROLL = "batch_nonmember_main_change_invalidates_roll"
    ROLL_MERGE_NOT_IN_MAIN_HISTORY = "batch_roll_merge_not_in_main_history"
    FINAL_LANDING_TREE_MISMATCH = "batch_final_landing_tree_mismatch"
    MEMBER_MOVED_DURING_CHECK = "batch_member_moved_during_check"
    PUBLICATION_CHANGED_DURING_CHECK = "batch_publication_changed_during_check"
    MEMBER_REVIEW_CHANGED_DURING_CHECK = "batch_member_review_changed_during_check"
    ROLL_OR_MAIN_MOVED_DURING_CHECK = "batch_roll_or_main_moved_during_check"


class Refusal(Exception):
    """A batch refusal: one Reason and the exit code chosen where it is raised.

    Shared ROLL/member readers take the code of the role their caller names,
    and shell guard failures take it from the guard's exit status, so one
    Reason can leave with different codes.
    """

    def __init__(self, reason: Reason, code: ExitCode):
        super().__init__(reason.value)
        self.reason = reason
        self.code = code


def failure_code(f, error):
    """Exit code of a failed batch evaluation, chosen by exception type only."""
    if isinstance(error, Refusal):
        return error.code
    if isinstance(error, (f.Unavailable, OSError)):
        # A parent read (gh, git, API shape) failed before any judgment.
        return ExitCode.INFRASTRUCTURE
    if isinstance(error, (ValueError, KeyError, TypeError)):
        return ExitCode.INVALID
    raise TypeError("unclassified batch failure: " + type(error).__name__) from error


def guard_check(args, failure):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode:
        # Existing read-only guards distinguish refusal (2) from API/infra
        # errors (1). Do not mislabel unavailable GitHub evidence as red CI.
        raise Refusal(Reason.EVIDENCE_READ_FAILED,
                      failure if result.returncode == 2 else ExitCode.INFRASTRUCTURE)
    return result.stdout


def merge_guard(args):
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
        raise Refusal(Reason.EVIDENCE_READ_FAILED, code)


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
            raise Refusal(Reason.TREE_MERGE_CONFLICT_OR_UNAVAILABLE,
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
            raise Refusal(Reason.TREE_COMMIT_UNAVAILABLE, ExitCode.INFRASTRUCTURE)
        return self.f.sha(result.stdout.strip())


def trusted_line(f, gh, prefix, pr, batch, *, failure=ExitCode.MEMBER):
    rows = [row for page in f.api_pages(
        gh, f"{prefix}/issues/{pr}/comments?per_page=100") for row in page]
    matches = [row for row in rows
               if batch.line in row.get("body", "").splitlines()
               and row.get("author_association") in {"OWNER", "MEMBER", "COLLABORATOR"}
               and row.get("user", {}).get("login") != batch.keeper]
    if not matches:
        raise Refusal(Reason.LINE_NOT_PUBLISHED_BY_TRUSTED_PARTICIPANT, failure)
    return tuple(sorted((row["id"], row["body"], row["author_association"]) for row in matches))


def current_checks(f, gh, repo, pr, head, git_dir, *, failure=ExitCode.MEMBER):
    """Use the very same live workflow/check gate as ordinary approval."""
    checks = Path(__file__).with_name("ci-checks.sh")
    guard_check(["bash", "-c",
        'GH="$1"; repo="$2"; pr="$3"; head="$4"; gitdir="$5"; '
        'source "$6"; check_current_ci',
        "batch-checks", gh, repo, str(pr), head, git_dir, str(checks)], failure)


def decision(f, gh, repo, member):
    reader = Path(__file__).with_name("review-verdict.sh")
    return f.command(["bash", "-c",
        'GH="$1"; repo="$2"; source "$3"; verdict_for "$4" "$5"',
        "batch-verdict", gh, repo, str(reader), str(member.pr), member.head]).split()


def member_review(f, gh, prefix, member, base, author):
    """A non-author's explicit review of exactly this member's full delta."""
    pattern = re.compile(
        r"member-review: COMPLETE pr: ([1-9][0-9]*) base: ([0-9a-f]{40}) "
        r"head: ([0-9a-f]{40}) scope: full-delta by: ([A-Za-z0-9._-]+)")
    rows = [row for page in f.api_pages(
        gh, f"{prefix}/pulls/{member.pr}/reviews?per_page=100") for row in page]
    valid = []
    for row in rows:
        if (row.get("state") not in {"COMMENTED", "APPROVED"}
                or row.get("author_association") not in {"OWNER", "MEMBER", "COLLABORATOR"}):
            continue
        login = row.get("user", {}).get("login")
        if not login or login == author:
            continue
        first = row.get("body", "").splitlines()[:1]
        match = pattern.fullmatch(first[0]) if first else None
        if not match:
            continue
        pr, reviewed_base, reviewed_head, keeper = match.groups()
        if (int(pr) != member.pr or reviewed_base != base or reviewed_head != member.head
                or row.get("commit_id") != member.head or keeper in {author, login}):
            continue
        review_id = row.get("id")
        submitted = row.get("submitted_at")
        if type(review_id) is not int or review_id <= 0 or not submitted:
            continue
        valid.append((review_id, login, keeper, submitted, row["body"]))
    if not valid:
        raise Refusal(Reason.MEMBER_WITHOUT_CURRENT_REVIEW, ExitCode.MEMBER)
    review_id, login, keeper, submitted, body = max(valid)
    return {"id": review_id, "login": login, "by": keeper, "submitted_at": submitted,
            "base": base, "head": member.head, "body": body}


def member_failure(f, gh, repo, member):
    value = decision(f, gh, repo, member)
    if value and value[0] == "FAIL":
        raise Refusal(Reason.MEMBER_HAS_LATE_FAIL, ExitCode.MEMBER)


def roll_review_state(f, gh, repo, member, run, *, required=False):
    value = decision(f, gh, repo, member)
    if (required or value) and (len(value) != 3 or value[0] != "PASS" or value[1] != str(run)):
        raise Refusal(Reason.ROLL_REVIEW_REFUSES_EVIDENCE, ExitCode.ROLL)
    review_state(f, gh, "repos/" + repo, member, failure=ExitCode.ROLL)


def review_state(f, gh, prefix, member, *, failure=ExitCode.MEMBER):
    rows = [row for page in f.api_pages(
        gh, f"{prefix}/pulls/{member.pr}/reviews?per_page=100") for row in page]
    latest = {}
    for row in sorted(rows, key=lambda row: row["id"]):
        if row["state"] in {"APPROVED", "CHANGES_REQUESTED", "DISMISSED"}:
            latest[row["user"]["login"]] = row
    if any(row["state"] == "CHANGES_REQUESTED" for row in latest.values()):
        raise Refusal(Reason.MEMBER_HAS_OPEN_CHANGE_REQUEST, failure)


def exact_run(f, gh, prefix, pr, head, branch, run_id, *, failure=ExitCode.MEMBER):
    run = f.api(gh, f"{prefix}/actions/runs/{run_id}")
    try:
        current = f.current_pr_check(gh, prefix, head, pr, branch)
    except f.NoPrCheckRun:
        # No PR-check run names this head: the role's own evidence is missing.
        # Other read failures keep their parent Unavailable type.
        raise Refusal(Reason.PR_CHECK_RUN_UNAVAILABLE, failure) from None
    if (run["id"] != run_id or run["head_sha"] != head
            or run["event"] != "pull_request" or run["path"] != ".github/workflows/pr-check.yml"
            or run["status"] != "completed" or run["conclusion"] != "success"
            or not f.run_names_candidate(run, pr, branch)
            or current != run_id):
        raise Refusal(Reason.RUN_NOT_CURRENT_SUCCESSFUL_EXACT_PR_CHECK, failure)
    if not run["pull_requests"]:
        suite = f.api(gh, f"{prefix}/check-suites/{run['check_suite_id']}")
        if (suite["head_sha"] != head or suite.get("head_branch") != branch
                or [row.get("number") for row in suite.get("pull_requests", [])] != [pr]):
            raise Refusal(Reason.RUN_SUITE_NOT_LINKED_TO_PR, failure)
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
        raise Refusal(Reason.REQUIRED_JOBS_NOT_ALL_SUCCESSFUL, failure)
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
        raise Refusal(Reason.ROLL_PR_IDENTITY_UNAVAILABLE, ExitCode.ROLL)
    roll, pull = matches[0]
    if roll.pr in {member.pr for member in batch.members}:
        raise Refusal(Reason.ROLL_PR_IS_A_MEMBER, ExitCode.INVALID)
    return roll, pull


def approvals(f, gh, repo, git_dir, members):
    guard = Path(__file__).with_name("approve-guard.sh")
    receipts = []
    for member in members:
        raw = guard_check(["bash", str(guard), "--merge-check", "--receipt-json", "--repo", repo,
                           "--pr", str(member.pr), "--head", member.head, "--git-dir", git_dir], ExitCode.MEMBER)
        try:
            receipt = json.loads(raw)
            if (receipt["pr"] != member.pr or receipt["head"] != member.head
                    or not receipt["approval_ids"]
                    or any(type(value) is not int or value <= 0 for value in receipt["approval_ids"])):
                raise ValueError("invalid approval receipt")
        except (ValueError, KeyError, TypeError):
            raise Refusal(Reason.INVALID_APPROVAL_RECEIPT, ExitCode.INFRASTRUCTURE)
        receipts.append(receipt)
    return receipts


def roll_input_snapshot(pull, batch):
    try:
        snapshot = roll_input.parse_body(pull.get("body"))
    except ValueError as error:
        raise Refusal(Reason.ROLL_INPUT_MISMATCH, ExitCode.ROLL) from error
    if (snapshot["base"] != batch.base
            or [(row["pr"], row["head"]) for row in snapshot["members"]]
            != [(row.pr, row.head) for row in batch.members]):
        raise Refusal(Reason.ROLL_INPUT_MISMATCH, ExitCode.ROLL)
    return snapshot


def roll_run_receipt(f, gh, repo, batch, roll_pr, roll_tree, snapshot, run_attempt):
    with tempfile.TemporaryDirectory(prefix="masc-roll-evidence-") as target:
        try:
            f.command([gh, "run", "download", str(batch.run), "--repo", repo,
                       "--name", "roll-evidence", "--dir", target])
            raw = (Path(target) / "roll-evidence.json").read_text()
            value = json.loads(raw)
        except (OSError, ValueError, f.Unavailable) as error:
            raise Refusal(Reason.ROLL_RUN_RECEIPT_MISMATCH, ExitCode.ROLL) from error
    suites = value.get("required_suites") if isinstance(value, dict) else None
    executed = value.get("executed_suites") if isinstance(value, dict) else None
    checkout = value.get("checkout_commit") if isinstance(value, dict) else None
    if not isinstance(checkout, str) or not re.fullmatch(r"[0-9a-f]{40}", checkout):
        raise Refusal(Reason.ROLL_RUN_RECEIPT_MISMATCH, ExitCode.ROLL)
    try:
        commit = f.api(gh, f"repos/{repo}/git/commits/{checkout}")
    except f.Unavailable as error:
        raise Refusal(Reason.ROLL_RUN_RECEIPT_MISMATCH, ExitCode.ROLL) from error
    if (commit.get("sha") != checkout
            or commit.get("tree", {}).get("sha") != roll_tree
            or [row.get("sha") for row in commit.get("parents", [])]
            != [batch.base, batch.roll]):
        raise Refusal(Reason.ROLL_RUN_RECEIPT_MISMATCH, ExitCode.ROLL)
    if (not isinstance(value, dict)
            or value.get("schema") != "masc.roll.run.v1"
            or value.get("input_digest") != snapshot["digest"]
            or value.get("base") != snapshot["base"]
            or value.get("members") != snapshot["members"]
            or value.get("result") != "success"
            or value.get("missing_suites") != []
            or type(value.get("run_attempt")) is not int
            or value["run_attempt"] != run_attempt
            or value.get("roll_pr") != roll_pr
            or value.get("roll_head") != batch.roll
            or value.get("roll_tree") != roll_tree
            or type(value.get("run_id")) is not int or value["run_id"] != batch.run
            or not isinstance(suites, list) or not suites
            or not isinstance(executed, list)
            or any(not isinstance(s, str) or not s for s in suites + executed)
            or len(set(suites)) != len(suites)
            or len(set(executed)) != len(executed)
            or set(suites) != set(executed)):
        raise Refusal(Reason.ROLL_RUN_RECEIPT_MISMATCH, ExitCode.ROLL)
    return value


def same_pull(before, after):
    return (all(after.get(key) == before.get(key)
                for key in ("state", "draft", "merged", "merge_commit_sha"))
            and after["head"]["sha"] == before["head"]["sha"]
            and after["head"]["ref"] == before["head"]["ref"]
            and after["base"]["ref"] == before["base"]["ref"]
            and after["base"]["sha"] == before["base"]["sha"])


def evaluate(f, *, line, repo, pr, head, run, git_dir, gh, landing=False, expected_main=None):
    batch = parse(line)
    prefix = "repos/" + repo
    roll, roll_pull = resolve_roll(f, gh, repo, batch)
    snapshot = roll_input_snapshot(roll_pull, batch)
    arrived = bool(roll_pull.get("merged"))
    candidate = None if pr is None and head is None and run is None else Member(pr, head)
    if candidate is not None and candidate not in (*batch.members, roll):
        raise Refusal(Reason.CANDIDATE_NOT_IN_BATCH, ExitCode.MEMBER)
    if landing and candidate != roll:
        raise Refusal(Reason.LANDING_REQUIRES_ROLL, ExitCode.MEMBER)
    if candidate is not None and arrived:
        raise Refusal(Reason.ROLL_ALREADY_MERGED, ExitCode.MEMBER)
    if candidate is None and not arrived:
        raise Refusal(Reason.ROLL_NOT_YET_MERGED, ExitCode.MEMBER)
    if candidate == roll and run != batch.run:
        raise Refusal(Reason.ROLL_VERDICT_NAMES_ANOTHER_RUN, ExitCode.ROLL)
    if candidate is not None and candidate != roll and run is not None:
        raise Refusal(Reason.MEMBER_RUN_NOT_APPLICABLE, ExitCode.MEMBER)
    checked_run = exact_run(
        f, gh, prefix, roll.pr, roll.head, roll_pull["head"]["ref"],
        batch.run, failure=ExitCode.ROLL)
    if not arrived:
        current_checks(f, gh, repo, roll.pr, roll.head, git_dir, failure=ExitCode.ROLL)
    roll_review_state(f, gh, repo, roll, batch.run, required=landing)
    published = {roll.pr: trusted_line(f, gh, prefix, roll.pr, batch, failure=ExitCode.ROLL)}
    main = f.sha(f.api(gh, f"{prefix}/commits/main")["sha"])
    trees = Trees(f, git_dir)
    for identity in (batch.base, batch.roll, main, *(member.head for member in batch.members)):
        trees.ensure(identity)
    tested_tree = trees.tree(trees.merge(batch.base, batch.roll))
    run_receipt = roll_run_receipt(
        f, gh, repo, batch, roll.pr, tested_tree, snapshot, checked_run.get("run_attempt"))

    pulls, member_reviews = {}, {}
    previous = None
    for index, member in enumerate(batch.members):
        pull = f.api(gh, f"{prefix}/pulls/{member.pr}")
        pulls[member.pr] = pull
        parent_ref = pulls[previous.pr]["head"]["ref"] if previous is not None else None
        if pull["base"]["ref"] == "main":
            expected_base = batch.base
        elif previous is not None and pull["base"]["ref"] == parent_ref:
            expected_base = previous.head
            if pull["base"]["sha"] != expected_base:
                raise Refusal(Reason.MEMBER_HEAD_OR_BASE_CHANGED, ExitCode.MEMBER)
        else:
            raise Refusal(Reason.MEMBER_HEAD_OR_BASE_CHANGED, ExitCode.MEMBER)
        if (pull["head"]["sha"] != member.head or pull["draft"]
                or snapshot["members"][index]["review_base"] != expected_base):
            raise Refusal(Reason.MEMBER_HEAD_OR_BASE_CHANGED, ExitCode.MEMBER)
        ancestry = subprocess.run(trees.git + ["merge-base", "--is-ancestor", expected_base,
                                              member.head], capture_output=True)
        if ancestry.returncode == 1:
            raise Refusal(Reason.MEMBER_HEAD_OR_BASE_CHANGED, ExitCode.MEMBER)
        if ancestry.returncode:
            raise Refusal(Reason.TREE_MERGE_CONFLICT_OR_UNAVAILABLE, ExitCode.INFRASTRUCTURE)
        # Original PRs are absorbed, never individually merged by this path.
        # After verified publication, a Keeper may already have closed some.
        if pull.get("merged") or (not arrived and pull["state"] != "open"):
            raise Refusal(Reason.MEMBER_NO_LONGER_OPEN, ExitCode.MEMBER)
        published[member.pr] = trusted_line(f, gh, prefix, member.pr, batch)
        member_reviews[member.pr] = member_review(
            f, gh, prefix, member, expected_base, pull["user"]["login"])
        review_state(f, gh, prefix, member)
        member_failure(f, gh, repo, member)
        previous = member

    reconstructed, member_paths = batch.base, set()
    for member in batch.members:
        before = reconstructed
        reconstructed = trees.merge(reconstructed, member.head)
        member_paths.update(trees.paths(before, reconstructed))
    if trees.tree(reconstructed) != trees.tree(batch.roll):
        raise Refusal(Reason.ROLL_TREE_DOES_NOT_MATCH_MEMBERS, ExitCode.LANDING)
    if not trees.paths(batch.base, batch.roll):
        raise Refusal(Reason.ROLL_HAS_NO_CHANGES, ExitCode.INVALID)

    merge_commit = f.sha(roll_pull["merge_commit_sha"]) if arrived else None
    history, commit = [], main
    while commit != batch.base:
        row = trees.read("show", "--no-patch", "--format=%H %P", commit).split()
        if len(row) < 2:
            raise Refusal(Reason.BASE_NOT_IN_AVAILABLE_MAIN_HISTORY, ExitCode.INFRASTRUCTURE)
        history.append((commit, row[1], len(row) - 1))
        commit = row[1]
    seen, external, landing_parent = False, set(), None
    post_landing_commits = []
    for commit, parent, parent_count in reversed(history):
        if commit == merge_commit:
            if parent_count != 1:
                raise Refusal(Reason.ROLL_LANDING_IS_NOT_A_SQUASH, ExitCode.LANDING)
            if expected_main is not None and parent != expected_main:
                raise Refusal(Reason.MAIN_CHANGED_AT_MERGE_WRITE, ExitCode.LANDING)
            if trees.tree(trees.merge(parent, batch.roll)) != trees.tree(commit):
                raise Refusal(Reason.ROLL_LANDING_TREE_MISMATCH, ExitCode.LANDING)
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
                raise Refusal(Reason.NONMEMBER_MAIN_CHANGE_INVALIDATES_ROLL, ExitCode.MAIN_OVERLAP)
            external.update(touched)
    if arrived and not seen:
        raise Refusal(Reason.ROLL_MERGE_NOT_IN_MAIN_HISTORY, ExitCode.LANDING)
    final = merge_commit if arrived else trees.merge(main, batch.roll)
    if (trees.paths(batch.roll, final) - external
            or (not arrived and trees.paths(main, final) & external)):
        raise Refusal(Reason.FINAL_LANDING_TREE_MISMATCH, ExitCode.LANDING)

    # Recheck the same ROLL attempt, then member reviews and refusals.
    final_run = exact_run(
        f, gh, prefix, roll.pr, roll.head, roll_pull["head"]["ref"],
        batch.run, failure=ExitCode.ROLL)
    if final_run.get("run_attempt") != checked_run.get("run_attempt"):
        raise Refusal(Reason.ROLL_RUN_RECEIPT_MISMATCH, ExitCode.ROLL)
    if not arrived:
        current_checks(f, gh, repo, roll.pr, roll.head, git_dir, failure=ExitCode.ROLL)
    for member in batch.members:
        end = f.api(gh, f"{prefix}/pulls/{member.pr}")
        if not same_pull(pulls[member.pr], end):
            raise Refusal(Reason.MEMBER_MOVED_DURING_CHECK, ExitCode.MEMBER)
        if trusted_line(f, gh, prefix, member.pr, batch) != published[member.pr]:
            raise Refusal(Reason.PUBLICATION_CHANGED_DURING_CHECK, ExitCode.MEMBER)
        expected_base = member_reviews[member.pr]["base"]
        if member_review(f, gh, prefix, member, expected_base,
                         pulls[member.pr]["user"]["login"]) != member_reviews[member.pr]:
            raise Refusal(Reason.MEMBER_REVIEW_CHANGED_DURING_CHECK, ExitCode.MEMBER)
        review_state(f, gh, prefix, member)
        member_failure(f, gh, repo, member)
    end_roll = f.api(gh, f"{prefix}/pulls/{roll.pr}")
    if roll_input_snapshot(end_roll, batch) != snapshot:
        raise Refusal(Reason.ROLL_INPUT_MISMATCH, ExitCode.ROLL)
    roll_review_state(f, gh, repo, roll, batch.run, required=landing)
    if (not same_pull(roll_pull, end_roll)
            or trusted_line(f, gh, prefix, roll.pr, batch, failure=ExitCode.ROLL) != published[roll.pr]
            or f.sha(f.api(gh, f"{prefix}/commits/main")["sha"]) != main):
        raise Refusal(Reason.ROLL_OR_MAIN_MOVED_DURING_CHECK, ExitCode.INVALID)
    approval_receipts = None
    if landing:
        # The ROLL alone needs a bound approval. Member source reviews and
        # refusal state were re-read above; no member CI or approval is inferred.
        approval_receipts = approvals(f, gh, repo, git_dir, (roll,))
    result = {"status": "published" if arrived else "fresh", "kind": "batch", "head": head,
              "run": run, "main": main, "base": batch.base, "roll": batch.roll,
              "roll_pr": roll.pr, "roll_run": batch.run,
              "input_digest": snapshot["digest"], "run_receipt": run_receipt,
              "members": [{"pr": member.pr, "head": member.head,
                           "base": member_reviews[member.pr]["base"],
                           "review_id": member_reviews[member.pr]["id"]}
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


class LandStatus(Enum):
    """What land() reports. The value is the receipt's `status`."""
    PUBLISHED = "published"
    CHECKED = "checked"
    PENDING = "pending"


# Total over LandStatus; test_batch_evidence pins that every member has a code.
LAND_EXIT_CODES = {
    LandStatus.PUBLISHED: ExitCode.SUCCESS,
    LandStatus.CHECKED: ExitCode.SUCCESS,
    LandStatus.PENDING: ExitCode.PENDING,
}


@dataclass(frozen=True)
class Landing:
    status: LandStatus
    receipt: dict


def landing(status, receipt):
    return Landing(status, {**receipt, "status": status.value})


def land(f, *, batch_file, repo, git_dir, gh, check_only):
    """Keeper entry: publish the tested ROLL once, then prove its arrival.

    An asynchronous merge still pending after one read returns pending. Resume
    at the next work boundary; never poll or close original PRs here.
    """
    import tempfile
    batch = parse(Path(batch_file).read_text())
    roll, pull = resolve_roll(f, gh, repo, batch)
    if pull.get("merged"):
        # With no candidate, evaluate refuses unless the ROLL has arrived.
        return landing(LandStatus.PUBLISHED,
                       evaluate(f, line=batch.line, repo=repo, pr=None, head=None, run=None,
                                git_dir=git_dir, gh=gh))
    before = evaluate(f, line=batch.line, repo=repo, pr=roll.pr, head=roll.head,
                      run=batch.run, git_dir=git_dir, gh=gh, landing=True)
    observation = {"scope": "preflight_before_merge_guard_not_write_boundary",
                   "members": before["members"], "roll": batch.roll, "roll_run": batch.run,
                   "approvals": before["approval_observation"]}
    if check_only:
        return landing(LandStatus.CHECKED,
                       {"roll": batch.roll, "roll_pr": roll.pr,
                        "members": [member.pr for member in batch.members],
                        "preflight_observation": observation})
    with tempfile.TemporaryDirectory(prefix="masc-batch-evidence-") as tmp:
        frozen = Path(tmp) / "batch.txt"
        frozen.write_text(batch.line + "\n")
        merge_guard(["bash", str(Path(__file__).with_name("merge-guard.sh")),
                     "--repo", repo, "--pr", str(roll.pr), "--head", roll.head,
                     "--run", str(batch.run), "--git-dir", git_dir, "--batch", str(frozen)])
    pull = f.api(gh, f"repos/{repo}/pulls/{roll.pr}")
    if not pull.get("merged"):
        return landing(LandStatus.PENDING,
                       {"pr": roll.pr, "head": roll.head, "roll": batch.roll,
                        "preflight_observation": observation,
                        "message": "merge submitted; resume at next work boundary"})
    result = evaluate(f, line=batch.line, repo=repo, pr=None, head=None, run=None,
                      git_dir=git_dir, gh=gh, expected_main=before["main"])
    result["preflight_observation"] = observation
    return landing(LandStatus.PUBLISHED, result)


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
        landed = land(f, batch_file=args.batch, repo=args.repo, git_dir=args.git_dir,
                      gh=os.environ.get("GUARD_GH", "gh"), check_only=args.check_only)
        result = landed.receipt
        code = LAND_EXIT_CODES[landed.status]
    except (Refusal, f.Unavailable) as error:
        result = {"status": "unavailable", "reason": str(error)}
        code = failure_code(f, error)
    except (ValueError, KeyError, TypeError) as error:
        result = {"status": "unavailable", "reason": "invalid_evidence"}
        code = failure_code(f, error)
    except OSError as error:
        result = {"status": "unavailable", "reason": "evidence_read_failed"}
        code = failure_code(f, error)
    print(json.dumps(result, sort_keys=True))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
