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


def review_scope(pr):
    stack = pr.get("stack")
    return {"base_ref": pr["base"]["ref"], "base_sha": pr["base"]["sha"],
            "stack": None if stack is None else {"number": stack["number"],
                "position": stack["position"], "base_ref": stack["base"]["ref"]}}


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

    def commit_accounts(self, base, head):
        path = f"compare/{base}...{head}?per_page=100"
        pages = self.api(path, pages=True)
        if not isinstance(pages, list) or not pages:
            raise Unavailable(f"GET {path}: expected comparison pages")
        total = None
        commits, accounts, account_names = set(), {}, {}
        complete = True
        for page in pages:
            if (not isinstance(page, dict) or not isinstance(page.get("base_commit"), dict)
                    or page["base_commit"].get("sha") != base
                    or type(page.get("total_commits")) is not int
                    or page["total_commits"] < 0 or not isinstance(page.get("commits"), list)):
                raise Unavailable(f"GET {path}: invalid comparison page")
            if total is not None and total != page["total_commits"]:
                raise Unavailable(f"GET {path}: inconsistent commit count")
            total = page["total_commits"]
            for commit in page["commits"]:
                if not isinstance(commit, dict) or not isinstance(commit.get("sha"), str) \
                        or re.fullmatch(r"[0-9a-f]{40}", commit["sha"]) is None \
                        or commit["sha"] in commits:
                    raise Unavailable(f"GET {path}: invalid or duplicate commit")
                commits.add(commit["sha"])
                for role in ("author", "committer"):
                    person = commit.get(role)
                    login = person.get("login") if isinstance(person, dict) else None
                    actor_id = person.get("id") if isinstance(person, dict) else None
                    if (not isinstance(login, str) or not login or any(c.isspace() for c in login)
                            or type(actor_id) is not int or actor_id < 1):
                        complete = False
                    else:
                        key = login.casefold()
                        if ((key in accounts and accounts[key][1] != actor_id)
                                or (actor_id in account_names and account_names[actor_id] != key)):
                            complete = False
                        accounts.setdefault(key, (login, actor_id))
                        account_names.setdefault(actor_id, key)
        complete = complete and len(commits) == total
        return tuple(accounts[k] for k in sorted(accounts)), complete

    def admission(self, pr, reviews, commit_accounts, identities_complete):
        if not identities_complete or pr["draft"] or pr["state"] != "open" or not any(
                r["state"] == "APPROVED" for r in reviews):
            return False
        # Reuse existing complete-diff/scope authority. Refusal is not a read
        # error; unreadable evidence must abort planning before any mutation.
        release = pr["head"]["ref"].startswith("release/v")
        mode = "--merge-check" if release else "--source-receipt"
        flags = [mode] + (["--receipt-json"] if release else [])
        result = command(["bash", str(HERE / "approve-guard.sh"), *flags,
                          "--repo", self.repo, "--pr", str(pr["number"]),
                          "--head", pr["head"]["sha"]],
                         env=dict(os.environ, GUARD_GH=self.gh))
        if result.returncode not in (0, 2):
            raise Unavailable(f"review admission #{pr['number']}: {result.stderr.strip()}")
        if result.returncode == 2:
            return False
        try:
            receipt = json.loads(result.stdout)
            ids = receipt["approval_ids"]
            if (receipt["pr"] != pr["number"] or receipt["head"] != pr["head"]["sha"]
                    or receipt["scope"] != review_scope(pr)
                    or receipt["policy"] != ("release" if release else "source")
                    or not isinstance(ids, list) or not ids
                    or any(type(i) is not int or i < 1 for i in ids)):
                raise ValueError("invalid receipt scope")
            by_id = {r["id"]: r for r in reviews}
            admitted = [by_id[i] for i in ids]
            actors = [r["user"]["id"] for r in admitted if r["state"] == "APPROVED"]
            if len(actors) != len(ids) or any(type(a) is not int or a < 1 for a in actors):
                raise ValueError("invalid admitted reviewer")
        except (ValueError, KeyError, TypeError) as error:
            raise Unavailable(f"review admission #{pr['number']}: inconsistent receipt") from error
        excluded = {actor_id for _, actor_id in commit_accounts} | {pr["user"]["id"]}
        return any(review.get("commit_id") == pr["head"]["sha"] and actor not in excluded
                   for review, actor in zip(admitted, actors))

    def independent_source_review(self, pr, reviews, comments, commit_accounts, identities_complete):
        # A valid independent source review may coexist with somebody else's
        # unresolved CR. It suppresses a duplicate request; it never admits a
        # PR or resolves a blocker. Releases still require their CI policy.
        if (not identities_complete or pr["draft"] or pr["state"] != "open"
                or pr["head"]["ref"].startswith("release/v")):
            return False
        excluded = {actor_id for _, actor_id in commit_accounts} | {pr["user"]["id"]}
        latest = {}
        for review in reviews:
            if review.get("state") not in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED"):
                continue
            user = review.get("user")
            actor_id = user.get("id") if isinstance(user, dict) else None
            rid = review.get("id")
            if type(actor_id) is not int or actor_id < 1 or type(rid) is not int or rid < 1:
                raise Unavailable(f"#{pr['number']}: review identity unavailable")
            if actor_id not in latest or rid > latest[actor_id]["id"]:
                latest[actor_id] = review
        conflicts = any(r["id"] in excluded for r in pr["requested_reviewers"])
        conflicts |= any(actor_id in excluded and r["state"] == "CHANGES_REQUESTED"
                         for actor_id, r in latest.items())
        candidates = [r for actor_id, r in latest.items()
                      if actor_id not in excluded and r["state"] == "APPROVED"
                      and r.get("commit_id") == pr["head"]["sha"]]
        if not conflicts or not candidates:
            return False
        base, head = pr["base"]["sha"], pr["head"]["sha"]
        decisions = module("worklist_source_decisions", "review-decisions.py")
        envelopes = ([{"kind": "review", "record": r} for r in reviews]
                     + [{"kind": "comment", "record": c} for c in comments])
        try:
            def record_actor(record, actor):
                person = record.get("user")
                if (not isinstance(person, dict) or type(person.get("id")) is not int
                        or person["id"] < 1 or not isinstance(person.get("login"), str)
                        or actor is None or person["login"].casefold() != actor.casefold()):
                    return None
                return person["id"]

            # Reduction groups by login. Without every decision's user ID,
            # a later record cannot be proven to belong to the same account.
            for ordinal, envelope in enumerate(envelopes):
                decision = decisions.parse_record(envelope, head=head, ordinal=ordinal)
                if decision is not None and record_actor(envelope["record"], decision.actor) is None:
                    return False
            reduction = decisions.reduce_decisions(envelopes, head=head)
            records = {}
            for envelope in envelopes:
                record = envelope["record"]
                record_id = record.get("id")
                if type(record_id) is not int or record_id < 1:
                    continue
                key = (envelope["kind"], record_id)
                if key in records:
                    raise ValueError("duplicate decision record")
                records[key] = record

            def decision_actor(decision):
                record = records.get((decision.kind.value, decision.record_id))
                return record_actor(record, decision.actor) if record is not None else None

            blockers = {decision_actor(d) for d in reduction.blockers}
            passes = {decision_actor(d) for d in reduction.decisions
                      if d.state is decisions.State.PASS}
        except (ValueError, KeyError, TypeError) as error:
            raise Unavailable(f"review source #{pr['number']}: decision unavailable") from error
        if None in blockers:
            return False
        candidates = [r for r in candidates if r["user"]["id"] in passes
                      and r["user"]["id"] not in blockers]
        if not candidates:
            return False
        result = command(["python3", str(HERE / "review-diff.py"), "--repo", self.repo,
                          "--base", base, "--head", head],
                         env=dict(os.environ, GUARD_GH=self.gh))
        digest = result.stdout.strip()
        if result.returncode or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            raise Unavailable(f"review source #{pr['number']}: complete diff unavailable")
        refusal = module("worklist_review_refusal", "review-refusal.py")
        scope = module("worklist_review_scope", "review-scope.py")
        try:
            for review in candidates:
                if review.get("body") is not None and not isinstance(review["body"], str):
                    raise ValueError("invalid review body")
                if refusal.diagnose(review, head=head, policy="source", base_sha=base,
                                    current_diff=digest):
                    continue
                if scope.scope_matches(review.get("body") or "", base_ref=pr["base"]["ref"],
                        base_sha=base, stack=scope.stack_scope(pr.get("stack")), head=head,
                        merge_base=lambda b, h: scope.gh_merge_base(self.gh, self.repo, b, h)):
                    return True
        except (ValueError, KeyError, TypeError, OSError) as error:
            raise Unavailable(f"review source #{pr['number']}: scope unavailable") from error
        return False

    def collect_pr(self, pr):
        number = pr["number"]
        reviews = self.collection(f"pulls/{number}/reviews?per_page=100")
        comments = self.collection(f"issues/{number}/comments?per_page=100")
        if any(not isinstance(r, dict) for r in (*reviews, *comments)):
            raise Unavailable(f"#{number}: invalid review or comment record")
        accounts, identities_complete = self.commit_accounts(pr["base"]["sha"], pr["head"]["sha"])
        if any(not isinstance(r, dict) or not isinstance(r.get("login"), str) or not r["login"]
               or type(r.get("id")) is not int or r["id"] < 1
               for r in pr["requested_reviewers"]):
            raise Unavailable(f"#{number}: requested reviewer identity unavailable")
        known = dict(self.roster_accounts)
        people = [pr["user"], *pr["requested_reviewers"]]
        people.extend(r.get("user") for r in reviews)
        people.extend(c.get("user") for c in comments)
        people.extend({"login": name, "id": actor_id} for name, actor_id in accounts)
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
        decisions = module("worklist_decisions", "review-decisions.py")
        envelopes = ([{"kind": "review", "record": r} for r in reviews]
                     + [{"kind": "comment", "record": c} for c in comments])
        blockers = decisions.reduce_decisions(envelopes, head=pr["head"]["sha"]).to_json()["blockers"]
        admitted = self.admission(pr, reviews, accounts, identities_complete)
        independent_review = admitted or self.independent_source_review(
            pr, reviews, comments, accounts, identities_complete)
        if admitted or independent_review:
            after = self.api(f"pulls/{number}")
            after_accounts, after_complete = self.commit_accounts(pr["base"]["sha"], pr["head"]["sha"])
            after_reviews = self.collection(f"pulls/{number}/reviews?per_page=100")
            after_comments = self.collection(f"issues/{number}/comments?per_page=100")
            final = self.api(f"pulls/{number}")
            if (pr_identity(after) != pr_identity(pr) or pr_identity(final) != pr_identity(pr)
                    or after_accounts != accounts or after_complete != identities_complete
                    or after_reviews != reviews or after_comments != comments):
                raise Unavailable(f"review admission #{number}: scope or commit identities changed")
        return {
            "number": number, "title": pr["title"], "url": pr["html_url"],
            "state": pr["state"], "draft": pr["draft"],
            "author": pr["user"]["login"], "author_id": pr["user"]["id"],
            "head": pr["head"]["sha"], "head_ref": pr["head"]["ref"],
            "base_ref": pr["base"]["ref"], "base_sha": pr["base"]["sha"],
            "stack": pr.get("stack"), "created_at": pr["created_at"],
            "requested_reviewers": tuple(r["login"] for r in pr["requested_reviewers"]),
            "requested_teams": tuple(t["slug"] for t in pr["requested_teams"]),
            "commit_accounts": tuple(name for name, _ in accounts),
            "commit_actor_ids": tuple(actor_id for _, actor_id in accounts),
            "account_ids": known, "commit_identities_complete": identities_complete,
            "reviews": tuple(reviews),
            "admission": admitted, "independent_source_review": independent_review,
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
        # Own-CR rereviews and replacement independent reviewers may coexist
        # with conflicting requests, but never displace a new valid request.
        independent_request = any(
            routing.reviewer_eligibility(parsed, actor) in
            (routing.ReviewerEligibility.ELIGIBLE, routing.ReviewerEligibility.UNKNOWN)
            for actor in live["requested_reviewers"])
        conflicts = any(a["reason"] == "independent_review" for a in proposed)
        first = any(a["reason"] not in ("changed_head_cr", "independent_review") for a in proposed)
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
            same_identities = None
            if present and same_scope:
                try:
                    accounts, complete = github.commit_accounts(live["base_sha"], live["head"])
                    same_identities = (tuple(name for name, _ in accounts) == live["commit_accounts"]
                                       and tuple(actor_id for _, actor_id in accounts) == live["commit_actor_ids"]
                                       and complete == live["commit_identities_complete"])
                except (Unavailable, ValueError, KeyError, TypeError, OSError):
                    pass
                try:
                    final = github.api(f"pulls/{number}")
                    same_scope = matches_snapshot(final, live)
                except (Unavailable, ValueError, KeyError, TypeError, OSError):
                    same_scope = None
            result.update(observed=present, scope_unchanged=same_scope,
                          identities_unchanged=same_identities)
            prefix = "observed_after_error" if posted.returncode else "requested"
            if wrong_identity:
                state = prefix + "_wrong_identity"
            elif not present:
                state = "request_unconfirmed"
            elif same_scope is None:
                state = prefix + "_scope_unconfirmed"
            elif not same_scope:
                state = prefix + "_scope_changed"
            elif same_identities is None:
                state = prefix + "_identity_unconfirmed"
            elif not same_identities:
                state = prefix + "_identity_changed"
            else:
                state = prefix
        except (Unavailable, ValueError, KeyError, TypeError, OSError):
            state = "request_unconfirmed"
        results.append(result | {"state": state,
                                 "planned_head": live["head"],
                                 "error": posted.stderr.strip() if posted.returncode else None})
        if posted.returncode or state in ("request_unconfirmed", "requested_identity_unconfirmed",
                                           "requested_scope_unconfirmed", "requested_wrong_identity"):
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
