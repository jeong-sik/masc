#!/usr/bin/env python3
"""Prepare the leader's explicitly selected, source-approved combined commit.

No build, CI dispatch, push or merge is performed. The existing source-review
guard supplies approval authority independently of CI.
"""
import argparse
from dataclasses import dataclass
from enum import Enum
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from batch_evidence import Trees, Refusal


class Reason(Enum):
    INVALID_SELECTION = "invalid_selection"
    APPROVAL_UNAVAILABLE = "approval_unavailable"
    MAIN_MOVED = "main_moved"
    APPROVAL_CHANGED = "approval_changed"
    UNSELECTED_BASE = "unselected_base"
    NO_CHANGES = "no_changes"


class SourceUnavailable(Exception):
    pass


class Rejected(Exception):
    def __init__(self, reason):
        super().__init__(reason.value)
        self.reason = reason


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


def prepare(f, *, repo, leader, selected, git_dir, gh, approve=source_approval):
    if (not selected or len({m.pr for m in selected}) != len(selected)
            or not leader.strip()
            or re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo) is None):
        raise Rejected(Reason.INVALID_SELECTION)
    for m in selected:
        f.sha(m.head)
    prefix = f"repos/{repo}"
    base = f.sha(f.api(gh, prefix + "/commits/main")["sha"])
    trees = Trees(f, git_dir)
    trees.ensure(base)
    approvals = tuple(approve(repo, m, gh=gh) for m in selected)
    combined = base
    for m in selected:
        pull = f.api(gh, prefix + f"/pulls/{m.pr}")
        if (pull["state"] != "open" or pull["draft"] is not False
                or pull["head"]["sha"] != m.head or pull["base"]["ref"] != "main"):
            raise Rejected(Reason.INVALID_SELECTION)
        parent = f.sha(pull["base"]["sha"])
        trees.ensure(parent)
        trees.ensure(m.head)
        check = subprocess.run(trees.git + ["merge-base", "--is-ancestor", parent, base],
                               capture_output=True)
        if check.returncode:
            raise Rejected(Reason.UNSELECTED_BASE)
        combined = trees.merge(combined, m.head)
    if trees.tree(combined) == trees.tree(base):
        raise Rejected(Reason.NO_CHANGES)
    # Re-read source authority after constructing the candidate. Old approval
    # evidence must not survive a head push, dismissal or change request.
    for initial in approvals:
        current = approve(repo, initial.member, gh=gh)
        if not set(initial.ids).issubset(current.ids):
            raise Rejected(Reason.APPROVAL_CHANGED)
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
    spec = importlib.util.spec_from_file_location("approved_batch_freshness",
                                                 Path(__file__).with_name("ci-freshness.py"))
    f = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = f
    spec.loader.exec_module(f)
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
        with output.open("x") as out:
            created = False
            try:
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
    except Refusal as error:
        unavailable = int(error.code) == 1
        print(json.dumps({"status": "unavailable" if unavailable else "refused", "reason": str(error)}))
        return 1 if unavailable else 2
    except Rejected as error:
        print(json.dumps({"status": "refused", "reason": str(error)}))
        return 2
    except (OSError, ValueError, KeyError, TypeError, SourceUnavailable, f.Unavailable):
        print(json.dumps({"status": "unavailable", "reason": "evidence_read_failed"}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
