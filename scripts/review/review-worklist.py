#!/usr/bin/env python3
"""Plan review work from GitHub facts; optionally request missing reviewers.

Requests are outstanding notifications, never claims, reviews or approvals.
No local queue, timer, CI dispatch, request removal or merge is involved.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from functools import cache
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent


@cache
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


def pr_identity(pr):
    return (pr["state"], pr["draft"], pr["head"]["sha"], pr["head"]["ref"],
            pr["base"]["sha"], pr["base"]["ref"], pr["user"]["id"],
            pr["user"]["login"], pr.get("stack"))


def matches_snapshot(pr, snapshot):
    return pr_identity(pr) == (snapshot["state"], snapshot["draft"], snapshot["head"],
            snapshot["head_ref"], snapshot["base_sha"], snapshot["base_ref"],
            snapshot["author_id"], snapshot["author"], snapshot["stack"])


class GitHub:
    def __init__(self, repo, gh="gh"):
        self.repo, self.gh = repo, gh
        self.roster_accounts = {}

    def resolve_account(self, name):
        result = command([self.gh, "api", f"users/{name}"])
        if result.returncode:
            raise Unavailable(f"GET users/{name}: {result.stderr.strip()}")
        try:
            user = json.loads(result.stdout)
            if (not isinstance(user.get("login"), str) or user["login"].casefold() != name.casefold()
                    or type(user.get("id")) is not int or user["id"] < 1):
                raise ValueError("non-current login or missing user id")
            return user["id"]
        except (ValueError, TypeError, AttributeError) as error:
            raise Unavailable(f"GET users/{name}: invalid account identity") from error

    def resolve_roster(self, roster):
        self.roster_accounts = {name.casefold(): self.resolve_account(name) for name in roster}

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

    def collect_pr(self, pr):
        number = pr["number"]
        reviews = self.collection(f"pulls/{number}/reviews?per_page=100")
        if any(not isinstance(r, dict) for r in reviews):
            raise Unavailable(f"#{number}: invalid review record")
        if any(not isinstance(r, dict) or not isinstance(r.get("login"), str) or not r["login"]
               or type(r.get("id")) is not int or r["id"] < 1
               for r in pr["requested_reviewers"]):
            raise Unavailable(f"#{number}: requested reviewer identity unavailable")
        known = dict(self.roster_accounts)
        people = [pr["user"], *pr["requested_reviewers"]]
        # Review records can contain an older login, including one later reused
        # by another account. Only current PR users and the resolved roster
        # provide login-to-ID mappings for prospective requests.
        for person in people:
            if not isinstance(person, dict):
                continue
            name, actor_id = person.get("login"), person.get("id")
            if not isinstance(name, str) or not name or type(actor_id) is not int or actor_id < 1:
                continue
            key = name.casefold()
            if key in known and known[key] != actor_id:
                raise Unavailable(f"#{number}: conflicting GitHub account identity")
            known[key] = actor_id
        native = module("worklist_github_reviews", "github-reviews.py")
        try:
            review_state = native.evaluate(pr, reviews, head=pr["head"]["sha"])
        except (ValueError, TypeError) as error:
            raise Unavailable(f"#{number}: review state unavailable: {error}") from error
        if review_state["approval_ids"]:
            after = self.api(f"pulls/{number}")
            after_reviews = self.collection(f"pulls/{number}/reviews?per_page=100")
            final = self.api(f"pulls/{number}")
            if (pr_identity(after) != pr_identity(pr) or pr_identity(final) != pr_identity(pr)
                    or after_reviews != reviews):
                raise Unavailable(f"review #{number}: scope or review evidence changed")
        return {
            "number": number, "title": pr["title"], "url": pr["html_url"],
            "state": pr["state"], "draft": pr["draft"],
            "author": pr["user"]["login"], "author_id": pr["user"]["id"],
            "head": pr["head"]["sha"], "head_ref": pr["head"]["ref"],
            "base_ref": pr["base"]["ref"], "base_sha": pr["base"]["sha"],
            "stack": pr.get("stack"), "created_at": pr["created_at"],
            "requested_reviewers": tuple(r["login"] for r in pr["requested_reviewers"]),
            "requested_teams": tuple(t["slug"] for t in pr["requested_teams"]),
            "account_ids": known,
            "reviews": tuple(reviews),
        }

    def snapshot(self):
        # Each detail read includes authoritative REST stack metadata. Finish
        # all collection/validation before emitting or applying a worklist.
        listed = self.collection("pulls?state=open&per_page=100")
        # Load helpers before workers start: some register modules during import.
        module("worklist_github_reviews", "github-reviews.py")
        def collect(item):
            return self.collect_pr(self.api(f"pulls/{item['number']}"))
        with ThreadPoolExecutor() as executor:
            return tuple(executor.map(collect, listed))


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
            routing = module("worklist_preflight_routing", "review-routing.py")
            parsed = routing.parse_pull(live)
        except (Unavailable, ValueError, KeyError, TypeError, OSError) as error:
            results.append(result | {"state": "unavailable", "error": str(error)})
            stopped = True
            continue
        if evidence(live) != evidence(original[number]):
            results.append(result | {"state": "snapshot_changed"})
            continue
        requested_ids = {live["account_ids"].get(a.casefold()) for a in live["requested_reviewers"]}
        missing_actions = [a for a in proposed if a["account_id"] not in requested_ids]
        missing = [a["account"] for a in missing_actions]
        if not missing:
            results.append(result | {"state": "already_requested"})
            continue
        # Own-CR rereviews and other eligible reviewers may coexist
        # with conflicting requests, but never displace a new valid request.
        independent_request = any(
            routing.reviewer_eligibility(parsed, actor) in
            (routing.ReviewerEligibility.ELIGIBLE, routing.ReviewerEligibility.UNKNOWN)
            for actor in live["requested_reviewers"])
        conflicts = any(a["reason"] == "non_author_review" for a in proposed)
        first = any(a["reason"] not in ("changed_head_cr", "non_author_review") for a in proposed)
        if ((first and (live["requested_reviewers"] or live["requested_teams"]))
                or (conflicts and (live["requested_teams"] or independent_request))):
            results.append(result | {"state": "assignment_changed"})
            continue
        try:
            current_ids = [github.resolve_account(a["account"]) for a in missing_actions]
        except (Unavailable, ValueError, KeyError, TypeError, OSError) as error:
            results.append(result | {"state": "unavailable", "error": str(error)})
            stopped = True
            continue
        if current_ids != [a["account_id"] for a in missing_actions]:
            results.append(result | {"state": "snapshot_changed"})
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
            if (not isinstance(after_requests, dict)
                    or not isinstance(after_requests.get("users"), list)
                    or any(not isinstance(a, dict) or not isinstance(a.get("login"), str)
                           or type(a.get("id")) is not int or a["id"] < 1
                           for a in after_requests["users"])):
                raise Unavailable(f"#{number}: requested reviewer readback identity unavailable")
            observed = {a["id"] for a in after_requests["users"]
                        if type(a.get("id")) is int and a["id"] > 0}
            present = all(a["account_id"] in observed for a in missing_actions)
            wrong_identity = any(a.get("login", "").casefold() in {x.casefold() for x in missing}
                                 and a.get("id") not in current_ids
                                 for a in after_requests["users"])
            same_scope = matches_snapshot(after, live)
            if present and same_scope:
                try:
                    final = github.api(f"pulls/{number}")
                    same_scope = matches_snapshot(final, live)
                except (Unavailable, ValueError, KeyError, TypeError, OSError):
                    same_scope = None
            result.update(observed=present, scope_unchanged=same_scope)
            prefix = "observed_after_error" if posted.returncode else "requested"
            if wrong_identity:
                state = prefix + "_wrong_identity"
            elif not present:
                state = "request_unconfirmed"
            elif same_scope is None:
                state = prefix + "_scope_unconfirmed"
            elif not same_scope:
                state = prefix + "_scope_changed"
            else:
                state = prefix
        except (Unavailable, ValueError, KeyError, TypeError, OSError):
            state = "request_unconfirmed"
        results.append(result | {"state": state,
                                 "planned_head": live["head"],
                                 "error": posted.stderr.strip() if posted.returncode else None})
        if posted.returncode or state in ("request_unconfirmed", "requested_scope_unconfirmed",
                                           "requested_wrong_identity"):
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
        github.resolve_roster(args.reviewer)
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
