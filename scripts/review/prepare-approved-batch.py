#!/usr/bin/env python3
"""Prepare the leader's explicitly selected, source-approved combined commit.

No build, CI dispatch, push or merge is performed. The existing source-review
guard supplies approval authority independently of CI.
"""
import argparse
from dataclasses import dataclass
from enum import Enum
import json
import os
from pathlib import Path
import re
import runpy
import subprocess
import sys


scope_matches = runpy.run_path(str(Path(__file__).with_name("review-scope.py")))["scope_matches"]

class Reason(Enum):
    INVALID_SELECTION = "invalid_selection"
    APPROVAL_UNAVAILABLE = "approval_unavailable"
    MAIN_MOVED = "main_moved"
    APPROVAL_CHANGED = "approval_changed"
    REVIEW_SCOPE_CHANGED = "review_scope_changed"
    UNSELECTED_BASE = "unselected_base"
    NO_CHANGES = "no_changes"
    MERGE_CONFLICT = "merge_conflict"
    SELECTION_CHANGED = "selection_changed"


class SourceUnavailable(Exception):
    pass


class Rejected(Exception):
    def __init__(self, reason):
        super().__init__(reason.value)
        self.reason = reason



def sha(value):
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{40}", value) is None:
        raise SourceUnavailable("invalid_commit_identity")
    return value


def command(args):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode:
        raise SourceUnavailable("command_failed")
    return result.stdout


def api(gh, endpoint):
    return json.loads(command([gh, "api", endpoint]))


class Trees:
    """Compose actual Git trees without changing a checkout or publishing."""
    def __init__(self, commands, git_dir, repo, gh):
        self.commands = commands
        self.git = ["git", "-C", git_dir]
        self.repo = repo
        self.gh = gh
        self.remote = None

    def ensure(self, commit):
        self.commands.sha(commit)
        present = subprocess.run(self.git + ["cat-file", "-e", commit + "^{commit}"],
                                 capture_output=True)
        if present.returncode:
            if self.remote is None:
                self.remote = self.commands.api(self.gh, f"repos/{self.repo}")["clone_url"]
                if not isinstance(self.remote, str) or not self.remote:
                    raise SourceUnavailable("repository_remote_unavailable")
            self.commands.command(self.git + ["fetch", "--quiet", "--no-tags", "--", self.remote, commit])
        self.commands.command(self.git + ["cat-file", "-e", commit + "^{commit}"])

    def merge_base(self, base, head):
        return self.commands.sha(self.commands.command(
            self.git + ["merge-base", base, head]).strip())

    def tree(self, commit):
        return self.commands.sha(self.commands.command(
            self.git + ["rev-parse", commit + "^{tree}"]).strip())

    def merge(self, left, right):
        result = subprocess.run(self.git + ["merge-tree", "--write-tree", left, right],
                                text=True, capture_output=True)
        if result.returncode == 1:
            raise Rejected(Reason.MERGE_CONFLICT)
        if result.returncode:
            raise SourceUnavailable("tree_merge_failed")
        tree = self.commands.sha(result.stdout.splitlines()[0])
        result = subprocess.run(self.git + ["-c", "user.name=Approved selection",
            "-c", "user.email=approved-selection@example.invalid", "-c", "commit.gpgSign=false",
            "commit-tree", tree, "-p", left, "-p", right],
            input="Explicit source-approved candidate\n", text=True, capture_output=True,
            env=os.environ | {"GIT_AUTHOR_DATE": "2000-01-01T00:00:00Z",
                              "GIT_COMMITTER_DATE": "2000-01-01T00:00:00Z"})
        if result.returncode:
            raise SourceUnavailable("tree_commit_failed")
        return self.commands.sha(result.stdout.strip())


@dataclass(frozen=True)
class Member:
    pr: int
    head: str


@dataclass(frozen=True)
class Approval:
    member: Member
    ids: tuple[int, ...]


def member(value):
    match = re.fullmatch(r"([1-9][0-9]*)@([0-9a-f]{40})", value)
    if match is None:
        raise argparse.ArgumentTypeError("member must be PR@SHA40")
    return Member(int(match[1]), match[2])


def source_approval(repo, selected, *, gh):
    guard = Path(__file__).with_name("approve-guard.sh")
    result = subprocess.run(
        ["bash", str(guard), "--merge-check", "--receipt-json",
         "--repo", repo, "--pr", str(selected.pr), "--head", selected.head],
        text=True, capture_output=True, env=os.environ | {"GUARD_GH": gh})
    if result.returncode == 2:
        raise Rejected(Reason.APPROVAL_UNAVAILABLE)
    if result.returncode:
        raise SourceUnavailable("source_approval_read_failed")
    value = json.loads(result.stdout)
    ids = value.get("approval_ids")
    if (value.get("pr") != selected.pr or value.get("head") != selected.head
            or not isinstance(ids, list) or not ids
            or any(type(i) is not int or i <= 0 for i in ids)
            or len(set(ids)) != len(ids)):
        raise Rejected(Reason.APPROVAL_UNAVAILABLE)
    return Approval(selected, tuple(sorted(ids)))


def stack_scope(pull):
    stack = pull.get("stack")
    if stack is None:
        return None
    return {"number": stack["number"], "position": stack["position"],
            "base_ref": stack["base"]["ref"]}


def scoped_approval(f, trees, repo, selected, pull, *, gh, approve):
    approval = approve(repo, selected, gh=gh)
    accepted = []
    for review_id in approval.ids:
        review = f.api(gh, f"repos/{repo}/pulls/{selected.pr}/reviews/{review_id}")
        def merge_base(base, head):
            trees.ensure(base)
            return trees.merge_base(base, head)
        if not scope_matches(review["body"], base_ref=pull["base"]["ref"],
                base_sha=pull["base"]["sha"], stack=stack_scope(pull),
                head=selected.head, merge_base=merge_base):
            continue
        accepted.append(review_id)
    if not accepted:
        raise Rejected(Reason.REVIEW_SCOPE_CHANGED)
    return Approval(selected, tuple(accepted))


def prepare(f, *, repo, leader, selected, git_dir, gh, approve=source_approval):
    if (not selected or len({m.pr for m in selected}) != len(selected)
            or not leader.strip()
            or re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo) is None):
        raise Rejected(Reason.INVALID_SELECTION)
    for m in selected:
        f.sha(m.head)
    prefix = f"repos/{repo}"
    base = f.sha(f.api(gh, prefix + "/commits/main")["sha"])
    trees = Trees(f, git_dir, repo, gh)
    trees.ensure(base)
    pulls = []
    identities = {}
    snapshots = {}
    for m in selected:
        pull = f.api(gh, prefix + f"/pulls/{m.pr}")
        if (pull["state"] != "open" or pull["draft"] is not False
                or pull["head"]["sha"] != m.head or pull["base"]["ref"] != "main"
                or pull["head"]["ref"].startswith("release/v")):
            raise Rejected(Reason.INVALID_SELECTION)
        parent = f.sha(pull["base"]["sha"])
        trees.ensure(parent)
        trees.ensure(m.head)
        check = subprocess.run(trees.git + ["merge-base", "--is-ancestor", parent, base],
                               capture_output=True)
        if check.returncode:
            raise Rejected(Reason.UNSELECTED_BASE)
        pulls.append(m)
        identities[m.pr] = (pull["base"]["ref"], pull["base"]["sha"],
                            pull["head"]["ref"], pull["head"]["sha"], stack_scope(pull))
        snapshots[m.pr] = pull
    approvals = tuple(scoped_approval(f, trees, repo, m, snapshots[m.pr],
                                     gh=gh, approve=approve) for m in pulls)
    combined = base
    for m in pulls:
        combined = trees.merge(combined, m.head)
    if trees.tree(combined) == trees.tree(base):
        raise Rejected(Reason.NO_CHANGES)
    # Re-read source authority after constructing the candidate. Old approval
    # evidence must not survive a head push, dismissal or change request.
    for initial in approvals:
        pull = f.api(gh, prefix + f"/pulls/{initial.member.pr}")
        if (pull["state"] != "open" or pull["draft"] is not False
                or (pull["base"]["ref"], pull["base"]["sha"],
                    pull["head"]["ref"], pull["head"]["sha"], stack_scope(pull)) != identities[initial.member.pr]):
            raise Rejected(Reason.SELECTION_CHANGED)
        current = scoped_approval(f, trees, repo, initial.member, pull, gh=gh, approve=approve)
        if not set(initial.ids).issubset(current.ids):
            raise Rejected(Reason.APPROVAL_CHANGED)
        # The authority reader can yield while the PR is being retargeted.
        latest = f.api(gh, prefix + f"/pulls/{initial.member.pr}")
        if (latest["state"] != "open" or latest["draft"] is not False
                or (latest["base"]["ref"], latest["base"]["sha"],
                    latest["head"]["ref"], latest["head"]["sha"], stack_scope(latest)) != identities[initial.member.pr]):
            raise Rejected(Reason.SELECTION_CHANGED)
    if f.sha(f.api(gh, prefix + "/commits/main")["sha"]) != base:
        raise Rejected(Reason.MAIN_MOVED)
    return {
        "schema_version": 1, "status": "prepared", "repo": repo,
        "leader": leader, "base": base, "candidate": combined,
        "tree": trees.tree(combined),
        "members": [{"pr": a.member.pr, "head": a.member.head,
                     "approval_ids": list(a.ids)} for a in approvals],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("repo", "leader", "git-dir", "branch", "output"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--member", type=member, action="append", required=True)
    args = parser.parse_args()
    f = sys.modules[__name__]
    try:
        git = ["git", "-C", args.git_dir]
        f.command(git + ["check-ref-format", "--branch", args.branch])
        if Path(args.output).exists():
            raise Rejected(Reason.INVALID_SELECTION)
        receipt = prepare(f, repo=args.repo, leader=args.leader,
                          selected=tuple(args.member), git_dir=args.git_dir,
                          gh=os.environ.get("GUARD_GH", "gh"))
        # Reserve the receipt before creating a ref. Roll back only our own
        # candidate ref if writing fails; never delete a concurrently moved ref.
        receipt["branch"] = args.branch
        output = Path(args.output)
        out = output.open("x")
        created = False
        try:
            with out:
                f.command(git + ["update-ref", "refs/heads/" + args.branch,
                                 receipt["candidate"], ""])
                created = True
                json.dump(receipt, out, indent=2, sort_keys=True)
                out.write("\n")
                out.flush()
                os.fsync(out.fileno())
        except BaseException:
            if created:
                subprocess.run(git + ["update-ref", "-d", "refs/heads/" + args.branch,
                                      receipt["candidate"]], capture_output=True)
            output.unlink(missing_ok=True)
            raise
        print(json.dumps(receipt, sort_keys=True))
        return 0
    except Rejected as error:
        print(json.dumps({"status": "refused", "reason": str(error)}))
        return 2
    except (OSError, ValueError, KeyError, TypeError, SourceUnavailable):
        print(json.dumps({"status": "unavailable", "reason": "evidence_read_failed"}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
