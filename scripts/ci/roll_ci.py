#!/usr/bin/env python3
"""Bind ROLL selection and successful executions to the shared input contract."""

import argparse
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from collections.abc import Callable
from pathlib import Path
from typing import Any

Selector = Callable[[list[str], str], dict[str, list[str]]]

ROOT = Path(__file__).resolve().parents[2]


def git(root: Path, *args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=root, text=True).strip()


def ancestor(root: Path, base: str, head: str) -> None:
    result = subprocess.run(
        ["git", "merge-base", "--is-ancestor", base, head], cwd=root, check=False
    )
    if result.returncode == 1:
        raise ValueError(f"{base} is not an ancestor of {head}")
    result.check_returncode()


def changed_paths(root: Path, base: str, head: str) -> list[str]:
    data = subprocess.check_output(
        ["git", "diff", "--name-only", "-z", base, head], cwd=root
    )
    paths = data.decode().rstrip("\0").split("\0") if data else []
    if any("\n" in path for path in paths):
        raise ValueError(
            "selector line input cannot represent a filename containing a newline"
        )
    return paths


def build_plan(
    root: Path,
    roll_input: dict[str, Any],
    pulls: dict[int, dict[str, Any]],
    pr: int,
    head: str,
    run_id: str,
    attempt: str,
    select: Selector,
    roll_body: str = "",
) -> dict[str, Any]:
    checkout = git(root, "rev-parse", "HEAD")
    base = roll_input["base"]
    ancestor(root, base, checkout)
    ancestor(root, head, checkout)
    parents = git(root, "rev-list", "--parents", "-n", "1", checkout).split()[1:]
    if parents != [base, head]:
        raise ValueError("merge checkout must have fixed BASE and ROLL head as parents")
    required: set[str] = set()
    direct: set[str] = set()
    ranges = [(base, checkout, roll_body)]
    previous = None
    for member in roll_input["members"]:
        pull = pulls[member["pr"]]
        if pull["state"] != "open" or pull["head"]["sha"] != member["head"]:
            raise ValueError(f"member #{member['pr']} closed or moved")
        if previous is None and pull["base"]["ref"] != "main":
            raise ValueError("the first stack member must target main")
        if previous is not None and pull["base"]["sha"] != previous:
            raise ValueError("member base chain differs from the declared stack")
        expected_review_base = (
            git(root, "merge-base", base, member["head"])
            if previous is None
            else previous
        )
        if member["review_base"] != expected_review_base:
            raise ValueError("member review_base does not cover its full delta")
        ancestor(root, member["review_base"], member["head"])
        ancestor(root, member["head"], head)
        ranges.append((member["review_base"], member["head"], pull["body"] or ""))
        previous = member["head"]
    for start, end, body in ranges:
        selection = select(changed_paths(root, start, end), body)
        required.update(selection["sources"])
        direct.update(selection["direct_sources"])
    if not required:
        raise ValueError("ROLL required suite union is empty")
    return {
        "schema": "masc.roll.run.v1",
        "input_digest": roll_input["digest"],
        "base": base,
        "members": roll_input["members"],
        "roll_pr": pr,
        "roll_head": head,
        "roll_tree": git(root, "rev-parse", "HEAD^{tree}"),
        "checkout_commit": checkout,
        "run_id": int(run_id),
        "run_attempt": int(attempt),
        "changed_files": changed_paths(root, base, checkout),
        "required_suites": sorted(required),
        "direct_sources": sorted(direct),
    }


def finish_receipt(
    plan: dict[str, Any], executed: list[str], status: int
) -> dict[str, Any]:
    required, actual = set(plan["required_suites"]), set(executed)
    missing, unexpected = sorted(required - actual), sorted(actual - required)
    return {
        **plan,
        "executed_suites": sorted(actual),
        "missing_suites": missing,
        "unexpected_suites": unexpected,
        "runner_exit": status,
        "result": "success"
        if required and not missing and not unexpected and status == 0
        else "failure",
    }


def select_sources(root: Path, paths: list[str], body: str) -> dict[str, list[str]]:
    with tempfile.TemporaryDirectory() as d:
        directory = Path(d)
        changed, text, result = [
            directory / name for name in ("changed", "body", "selection")
        ]
        changed.write_text("\n".join(paths) + "\n")
        text.write_text(body)
        subprocess.run(
            [
                "bash",
                str(root / "scripts/ci/run-edited-tests.sh"),
                "--select-only",
                str(changed),
                "--body-file",
                str(text),
                "--selection-file",
                str(result),
            ],
            cwd=root,
            check=True,
        )
        return json.loads(result.read_text())


def shared_input(body: str) -> dict[str, Any]:
    # The sole grammar/digest authority is owned by the review guard.
    spec = importlib.util.spec_from_file_location(
        "roll_input", ROOT / "scripts/review/roll_input.py"
    )
    if spec is None or spec.loader is None:
        raise ValueError("shared ROLL parser is unavailable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    parse_body: Callable[[str], dict[str, Any]] = module.parse_body
    return parse_body(body)


def gh(repo: str, path: str) -> dict[str, Any]:
    return json.loads(subprocess.check_output(["gh", "api", f"repos/{repo}/{path}"]))


def prepare(output: Path, github_output: Path) -> None:
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    pr = event["pull_request"]
    repo = os.environ["GITHUB_REPOSITORY"]
    current = gh(repo, f"pulls/{pr['number']}")
    if current["state"] != "open" or current["head"]["sha"] != pr["head"]["sha"]:
        raise ValueError("ROLL/current PR head moved since this workflow event")
    body = current["body"] or ""
    # Ordinary PRs retain their existing selection. Malformed ROLL declarations
    # reach the shared parser, including an old batch without its required input.
    is_roll = "masc-roll-input-v1" in body or any(
        line.startswith("batch: PASS landing: ROLL ") for line in body.splitlines()
    )
    if is_roll:
        roll_input = shared_input(body)
        commits = {roll_input["base"], pr["head"]["sha"]}
        for member in roll_input["members"]:
            commits.update((member["head"], member["review_base"]))
        for commit in sorted(commits):
            if subprocess.run(
                ["git", "cat-file", "-e", commit + "^{commit}"],
                cwd=ROOT,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            ).returncode:
                subprocess.run(
                    ["git", "fetch", "--no-tags", "origin", commit],
                    cwd=ROOT,
                    check=True,
                )
        pulls = {m["pr"]: gh(repo, f"pulls/{m['pr']}") for m in roll_input["members"]}
        plan = build_plan(
            ROOT,
            roll_input,
            pulls,
            pr["number"],
            pr["head"]["sha"],
            os.environ["GITHUB_RUN_ID"],
            os.environ["GITHUB_RUN_ATTEMPT"],
            lambda paths, text: select_sources(ROOT, paths, text),
            body,
        )
    else:
        base = pr["base"]["sha"]
        if git(ROOT, "rev-parse", "-q", "--verify", "HEAD^2") == pr["head"]["sha"]:
            base = git(ROOT, "rev-parse", "HEAD^1")
        plan = {"base": base, "roll_head": pr["head"]["sha"]}
    output.write_text(json.dumps(plan, indent=2) + "\n")
    with github_output.open("a") as f:
        f.write(f"base={plan['base']}\nroll={'true' if is_roll else 'false'}\n")


def run(plan_path: Path, output: Path, budget: int) -> int:
    plan = json.loads(plan_path.read_text())
    if git(ROOT, "rev-parse", "HEAD") != plan["checkout_commit"] or (
        git(ROOT, "rev-parse", "HEAD^{tree}") != plan["roll_tree"]
    ):
        raise ValueError("scope plan and executing checkout differ")
    with tempfile.TemporaryDirectory() as d:
        directory = Path(d)
        selection, executed = directory / "selection.json", directory / "executed.txt"
        selection.write_text(
            json.dumps(
                {
                    "sources": plan["required_suites"],
                    "direct_sources": plan["direct_sources"],
                }
            )
        )
        status = subprocess.run(
            [
                "bash",
                str(ROOT / "scripts/ci/run-edited-tests.sh"),
                "--run-selection",
                str(selection),
                "--executed-file",
                str(executed),
                "--budget-seconds",
                str(budget),
            ],
            cwd=ROOT,
            check=False,
        ).returncode
        receipt = finish_receipt(
            plan, executed.read_text().splitlines() if executed.exists() else [], status
        )
    output.write_text(json.dumps(receipt, indent=2) + "\n")
    print(
        f"ROLL {receipt['result']}: required={len(receipt['required_suites'])} "
        f"executed={len(receipt['executed_suites'])} missing={receipt['missing_suites']}"
    )
    return 0 if receipt["result"] == "success" else 1


def selection(sources: str, direct: str, named: str, output: Path) -> None:
    selected = set(sources.splitlines())
    selected.discard("")
    # A selected test missing from the final tree must stay required: execution
    # cannot certify it, and the receipt will reject the incomplete union.
    for name in named.split():
        if "/" in name:
            candidates = [ROOT / name]
        else:
            candidates = (
                list(ROOT.glob(f"test/**/{name}.ml"))
                + list(ROOT.glob(f"test/**/{name}.py"))
                + list(ROOT.glob(f"packages/*/test/**/{name}.ml"))
                + list(ROOT.glob(f"packages/*/test/**/{name}.py"))
            )
        candidates = [
            p for p in candidates if p.is_file() and p.suffix in (".ml", ".py")
        ]
        if len(candidates) != 1 or not candidates[0].resolve().is_relative_to(
            ROOT.resolve()
        ):
            raise ValueError(
                f"named suite must resolve to exactly one repository test: {name}"
            )
        path = str(candidates[0].relative_to(ROOT))
        if not (path.startswith("test/") or "/test/" in path) or not candidates[
            0
        ].stem.startswith("test_"):
            raise ValueError(f"not a test suite: {name}")
        selected.add(path)
    output.write_text(
        json.dumps(
            {
                "sources": sorted(selected),
                "direct_sources": sorted(set(direct.splitlines()) & selected),
            }
        )
        + "\n"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    prep = sub.add_parser("prepare")
    prep.add_argument("--output", type=Path, required=True)
    prep.add_argument("--github-output", type=Path, required=True)
    execute = sub.add_parser("run")
    execute.add_argument("--plan", type=Path, required=True)
    execute.add_argument("--output", type=Path, required=True)
    execute.add_argument("--budget-seconds", type=int, required=True)
    save = sub.add_parser("selection")
    save.add_argument("--sources", required=True)
    save.add_argument("--direct", required=True)
    save.add_argument("--named", required=True)
    save.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "selection":
        selection(args.sources, args.direct, args.named, args.output)
        return 0
    if args.command == "prepare":
        prepare(args.output, args.github_output)
        return 0
    return run(args.plan, args.output, args.budget_seconds)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"ROLL CI refused: {error}", file=sys.stderr)
        sys.exit(1)
