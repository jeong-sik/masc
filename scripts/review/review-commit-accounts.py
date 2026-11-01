#!/usr/bin/env python3
"""Collect the linked GitHub identities of all commits in a reviewed diff."""
import argparse
import json
import re
import subprocess
import sys


class InvalidComparison(ValueError):
    pass


def inspect_pages(base, pages):
    """Return linked accounts, completeness, and actionable missing evidence."""
    if not isinstance(pages, list) or not pages:
        raise InvalidComparison("expected comparison pages")
    total = None
    commits, accounts, account_names = set(), {}, {}
    complete = True
    problems = []
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
                    problems.append(f"{commit['sha']} {role} account unavailable")
                else:
                    key = login.casefold()
                    if ((key in accounts and accounts[key][1] != actor_id)
                            or (actor_id in account_names and account_names[actor_id] != key)):
                        complete = False
                        problems.append("conflicting account login/id mapping")
                    accounts.setdefault(key, (login, actor_id))
                    account_names.setdefault(actor_id, key)
    if len(commits) != total:
        complete = False
        problems.insert(0, f"comparison returned {len(commits)} of {total} commits")
    return tuple(accounts[k] for k in sorted(accounts)), complete, problems


def accounts_from_pages(base, pages):
    accounts, complete, _ = inspect_pages(base, pages)
    return accounts, complete


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
        accounts, complete, problems = inspect_pages(args.base, json.loads(result.stdout))
    except (subprocess.SubprocessError, OSError, ValueError) as error:
        print(f"approve-guard: commit identities unavailable: {error}", file=sys.stderr)
        return 1
    if not complete:
        unique = list(dict.fromkeys(problems))
        detail = "; ".join(unique[:5])
        if len(unique) > 5:
            detail += f"; {len(unique) - 5} more identity problems"
        print(f"approve-guard: commit author or committer identity is incomplete: {detail}", file=sys.stderr)
        return 2
    print(json.dumps({"accounts": accounts}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
