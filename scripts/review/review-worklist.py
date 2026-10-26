#!/usr/bin/env python3
"""Plan review work from GitHub facts; optionally request missing reviewers.

Requests are outstanding notifications, never claims, reviews or approvals.
No local queue, timer, CI dispatch, request removal or merge is involved.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    result = importlib.util.module_from_spec(spec)
    sys.modules[name] = result
    spec.loader.exec_module(result)
    return result


class Unavailable(Exception):
    pass


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str
    stderr: str


def command(argv, *, payload=None, env=None):
    result = subprocess.run(argv, input=payload, env=env, text=True,
                            capture_output=True)
    return CommandResult(result.returncode, result.stdout, result.stderr)


class GitHub:
    def __init__(self, repo, gh="gh"):
        self.repo, self.gh = repo, gh

    def api(self, path, *, pages=False):
        args = [self.gh, "api"] + (["--paginate", "--slurp"] if pages else [])
        result = command(args + [f"repos/{self.repo}/{path}"])
        if result.returncode:
            raise Unavailable(f"GET {path}: {result.stderr.strip()}")
        try:
            return json.loads(result.stdout)
        except ValueError as error:
            raise Unavailable(f"GET {path}: invalid JSON") from error

    def collection(self, path):
        pages = self.api(path, pages=True)
        if not isinstance(pages, list) or any(not isinstance(p, list) for p in pages):
            raise Unavailable(f"GET {path}: expected all array pages")
        return [item for page in pages for item in page]

    def admission(self, pr, reviews):
        if pr["draft"] or pr["state"] != "open" or not any(
                r["state"] == "APPROVED" for r in reviews):
            return False
        # Reuse existing complete-diff/scope authority. Refusal is not a read
        # error; unreadable evidence must abort planning before any mutation.
        release = pr["head"]["ref"].startswith("release/v")
        mode = "--merge-check" if release else "--source-receipt"
        result = command(["bash", str(HERE / "approve-guard.sh"), mode,
                          "--repo", self.repo, "--pr", str(pr["number"]),
                          "--head", pr["head"]["sha"]],
                         env=dict(os.environ, GUARD_GH=self.gh))
        if result.returncode not in (0, 2):
            raise Unavailable(f"review admission #{pr['number']}: {result.stderr.strip()}")
        return result.returncode == 0

    def collect_pr(self, pr):
        number = pr["number"]
        reviews = self.collection(f"pulls/{number}/reviews?per_page=100")
        comments = self.collection(f"issues/{number}/comments?per_page=100")
        decisions = module("worklist_decisions", "review-decisions.py")
        envelopes = ([{"kind": "review", "record": r} for r in reviews]
                     + [{"kind": "comment", "record": c} for c in comments])
        blockers = decisions.reduce_decisions(envelopes, head=pr["head"]["sha"]).to_json()["blockers"]
        return {
            "number": number, "title": pr["title"], "url": pr["html_url"],
            "state": pr["state"], "draft": pr["draft"],
            "author": pr["user"]["login"], "head": pr["head"]["sha"],
            "base_ref": pr["base"]["ref"], "base_sha": pr["base"]["sha"],
            "stack": pr.get("stack"), "created_at": pr["created_at"],
            "requested_reviewers": tuple(r["login"] for r in pr["requested_reviewers"]),
            "requested_teams": tuple(t["slug"] for t in pr["requested_teams"]),
            "reviews": tuple(reviews), "admission": self.admission(pr, reviews),
            "blockers": tuple(blockers),
        }

    def snapshot(self):
        # Each detail read includes authoritative REST stack metadata. Finish
        # all collection/validation before emitting or applying a worklist.
        listed = self.collection("pulls?state=open&per_page=100")
        return tuple(self.collect_pr(self.api(f"pulls/{p['number']}")) for p in listed)


def evidence(snapshot):
    # Requests may have been added since planning. They are preserved, not
    # overwritten; all other decision inputs must still match before a POST.
    return {key: value for key, value in snapshot.items()
            if key not in ("requested_reviewers", "requested_teams")}


def apply_requests(github, snapshot, worklist):
    actions = worklist.to_json()["actions"]
    groups = {}
    for action in actions:
        if action["assignment"] == "proposed_user":
            groups.setdefault(action["number"], []).append(action)
    original = {p["number"]: p for p in snapshot}
    results = []
    stopped = False
    for number, proposed in groups.items():
        accounts = [a["account"] for a in proposed]
        result = {"number": number, "reviewers": accounts}
        if stopped:
            results.append(result | {"state": "not_attempted"})
            continue
        try:
            live = github.collect_pr(github.api(f"pulls/{number}"))
        except (Unavailable, ValueError, KeyError, TypeError, OSError) as error:
            results.append(result | {"state": "unavailable", "error": str(error)})
            stopped = True
            continue
        if evidence(live) != evidence(original[number]):
            results.append(result | {"state": "snapshot_changed"})
            continue
        requested = {a.casefold() for a in live["requested_reviewers"]}
        missing = [a for a in accounts if a.casefold() not in requested]
        if not missing:
            results.append(result | {"state": "already_requested"})
            continue
        # A new user/team request changes unassigned first-review routing.
        # Own-CR rereviews remain per-account work and may coexist with it.
        if ((live["requested_reviewers"] or live["requested_teams"])
                and any(a["reason"] != "changed_head_cr" for a in proposed)):
            results.append(result | {"state": "assignment_changed"})
            continue
        result["reviewers"] = missing
        try:
            posted = command([github.gh, "api", "--method", "POST",
                              f"repos/{github.repo}/pulls/{number}/requested_reviewers",
                              "--input", "-"], payload=json.dumps({"reviewers": missing}))
        except OSError as error:
            posted = CommandResult(1, "", str(error))
        # A failure can have an uncertain effect. Reconcile once and stop
        # further notifications; never blindly retry a POST.
        try:
            after = github.api(f"pulls/{number}")
            after_requests = github.api(f"pulls/{number}/requested_reviewers")
            observed = {a["login"].casefold() for a in after_requests["users"]}
            present = all(a.casefold() in observed for a in missing)
            same_scope = (after["state"] == live["state"] and after["draft"] == live["draft"]
                          and after["head"]["sha"] == live["head"]
                          and after["base"]["sha"] == live["base_sha"]
                          and after["base"]["ref"] == live["base_ref"]
                          and after.get("stack") == live["stack"])
            if posted.returncode:
                state = "observed_after_error" if present else "request_unconfirmed"
            elif not same_scope:
                state = "requested_scope_changed"
            else:
                state = "requested" if present else "request_unconfirmed"
        except (Unavailable, ValueError, KeyError, TypeError, OSError):
            state = "request_unconfirmed"
        results.append(result | {"state": state,
                                 "planned_head": live["head"],
                                 "error": posted.stderr.strip() if posted.returncode else None})
        if posted.returncode or state == "request_unconfirmed":
            stopped = True
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--reviewer", action="append", required=True,
                        help="Eligible GitHub login; repeat for a reviewer pool")
    parser.add_argument("--gh", default="gh", help="GitHub CLI executable")
    parser.add_argument("--request", action="store_true",
                        help="Publish missing review requests, then read them back")
    args = parser.parse_args()
    if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo) is None:
        parser.error("--repo must be OWNER/REPO")
    try:
        github = GitHub(args.repo, args.gh)
        snapshot = github.snapshot()
        routing = module("review_routing", "review-routing.py")
        worklist = routing.plan(snapshot, args.reviewer)
        payload = {"repo": args.repo, "status": "planned", **worklist.to_json()}
        if args.request:
            payload["requests"] = apply_requests(github, snapshot, worklist)
            payload["status"] = "requests_processed"
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0
    except (Unavailable, ValueError, KeyError, TypeError, OSError) as error:
        print(json.dumps({"status": "unavailable", "reason": str(error)}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
