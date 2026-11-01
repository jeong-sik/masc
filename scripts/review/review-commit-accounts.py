#!/usr/bin/env python3
"""Collect the linked GitHub identities of all commits in a reviewed diff."""
import argparse
import json
import re
import subprocess
import sys


class InvalidComparison(ValueError):
    pass


def accounts_from_pages(base, pages):
    """Return linked (login, id) pairs and whether every role was identified."""
    if not isinstance(pages, list) or not pages:
        raise InvalidComparison("expected comparison pages")
    total = None
    commits, accounts, account_names = set(), {}, {}
    complete = True
    for page in pages:
        if (not isinstance(page, dict) or not isinstance(page.get("base_commit"), dict)
                or page["base_commit"].get("sha") != base
                or type(page.get("total_commits")) is not int
                or page["total_commits"] < 0 or not isinstance(page.get("commits"), list)):
            raise InvalidComparison("invalid comparison page")
        if total is not None and total != page["total_commits"]:
            raise InvalidComparison("inconsistent commit count")
        total = page["total_commits"]
        for commit in page["commits"]:
            if (not isinstance(commit, dict) or not isinstance(commit.get("sha"), str)
                    or re.fullmatch(r"[0-9a-f]{40}", commit["sha"]) is None
                    or commit["sha"] in commits):
                raise InvalidComparison("invalid or duplicate commit")
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--gh", default="gh")
    args = parser.parse_args()
    path = f"repos/{args.repo}/compare/{args.base}...{args.head}?per_page=100"
    try:
        result = subprocess.run([args.gh, "api", "--paginate", "--slurp", path],
                                capture_output=True, text=True, check=True)
        accounts, complete = accounts_from_pages(args.base, json.loads(result.stdout))
    except (subprocess.SubprocessError, OSError, ValueError) as error:
        print(f"approve-guard: commit identities unavailable: {error}", file=sys.stderr)
        return 1
    if not complete:
        print("approve-guard: commit author or committer identity is incomplete", file=sys.stderr)
        return 2
    print(json.dumps({"accounts": accounts}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
