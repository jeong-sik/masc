#!/usr/bin/env python3
"""Exercise the actual workflow commands against local shallow Git fixtures."""

import argparse
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path
import subprocess

import yaml


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[3])
parser.add_argument("--output-dir", type=Path)
args = parser.parse_args()
WORKTREE = args.repo.resolve()
RUN = (args.output_dir.resolve() if args.output_dir else
       WORKTREE / "artifacts/changelog-local-diff" /
       datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ"))
RUN.mkdir(parents=True, exist_ok=False)
WORKFLOW = WORKTREE / ".github/workflows/changelog-fragments.yml"
CHECKER = WORKTREE / "scripts/changelog-fragments.py"
document = yaml.load(WORKFLOW.read_text(), Loader=yaml.BaseLoader)
steps = document["jobs"]["check"]["steps"]
checkout = next(step for step in steps if "uses" in step)
pr_step = next(step for step in steps if step.get("if") == "github.event_name == 'pull_request'")
dispatch_step = next(step for step in steps if step.get("if") == "github.event_name == 'workflow_dispatch'")
assert checkout["with"]["fetch-depth"] == "2"
assert "ref" not in checkout["with"], "pull_request must retain the event merge checkout"
assert document["on"]["workflow_dispatch"] == {}
assert dispatch_step["run"] == "python3 scripts/changelog-fragments.py check --dir changelog.d"

ENV = dict(os.environ)
ENV.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull})
for key in ("GH_TOKEN", "GITHUB_TOKEN", "PR_URL"):
    ENV.pop(key, None)


def git(repo: Path, *args: str) -> str:
    result = subprocess.run([
        "git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
        "-c", "user.name=Changelog fixture", "-c", "user.email=fixture@example.invalid",
        *args,
    ], cwd=repo, env=ENV, text=True, capture_output=True, check=True)
    return result.stdout.strip()


def write(repo: Path, path: str, text: str) -> None:
    target = repo / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)


def fragment(number: int) -> str:
    return f"### Internal\n\n- Fixture change (#{number})\n"


WRAPPER = '''import json, os, pathlib, runpy, sys
pathlib.Path(os.environ["FIXTURE_ARGS"]).write_text(json.dumps(sys.argv[1:]))
runpy.run_path("scripts/changelog-fragments-real.py", run_name="__main__")
'''


def fixture(name: str, *, base=None, changes=None, advance=None, depth=2) -> Path:
    case = RUN / name
    case.mkdir(parents=True)
    repo = case / "source"
    repo.mkdir()
    git(repo, "init", "-b", "main")
    write(repo, "seed.txt", "older history outside the shallow checkout\n")
    git(repo, "add", "--all")
    git(repo, "commit", "-m", "older history")
    write(repo, "scripts/changelog-fragments.py", WRAPPER)
    write(repo, "scripts/changelog-fragments-real.py", CHECKER.read_text())
    # An unchanged malformed lower-layer fragment must never be checked by a PR.
    for path, text in (base if base is not None else {"changelog.d/10.md": "malformed lower fragment\n"}).items():
        write(repo, path, text)
    write(repo, "base.txt", "base\n")
    git(repo, "add", "--all")
    git(repo, "commit", "-m", "base")
    git(repo, "checkout", "-b", "pr-changes")
    for path, text in (changes or {}).items():
        if text is None:
            (repo / path).unlink()
        else:
            write(repo, path, text)
    git(repo, "add", "--all")
    git(repo, "commit", "--allow-empty", "-m", "PR changes")
    git(repo, "checkout", "main")
    if advance:
        for path, text in advance.items():
            write(repo, path, text)
        git(repo, "add", "--all")
        git(repo, "commit", "-m", "base advances independently")
    git(repo, "merge", "--no-ff", "--no-edit", "refs/heads/pr-changes")
    git(repo, "rev-parse", "--verify", "HEAD^2")
    git(repo, "branch", "synthetic-merge")
    checkout = case / "checkout"
    git(case, "clone", "--depth", str(depth), "--branch", "synthetic-merge", repo.as_uri(), str(checkout))
    git(checkout, "checkout", "--detach")
    assert git(checkout, "rev-parse", "--is-shallow-repository") == "true"
    # A gh invocation is an unexpected dependency, even if authentication exists.
    shims = case / "bin"
    shims.mkdir()
    write(shims, "gh", "#!/bin/sh\necho unexpected gh invocation >&2\nexit 79\n")
    (shims / "gh").chmod(0o755)
    return checkout


results = []


def run_case(name: str, *, expected_files, success: bool, dispatch=False, **options) -> None:
    checkout = fixture(name, **options)
    case = checkout.parent
    args_path = case / "checker-args.json"
    env = dict(ENV, FIXTURE_ARGS=str(args_path))
    env["PATH"] = str(case / "bin") + os.pathsep + env["PATH"]
    step = dispatch_step if dispatch else pr_step
    result = subprocess.run(["bash", "-e", "-c", step["run"]], cwd=checkout, env=env,
                            text=True, capture_output=True)
    args = json.loads(args_path.read_text()) if args_path.exists() else None
    expected_args = (["check", "--dir", "changelog.d"] if dispatch else
                     ["check-files", *expected_files] if expected_files is not None else None)
    assert args == expected_args, (name, "argv", args, expected_args)
    assert (result.returncode == 0) == success, (name, result.returncode, result.stdout, result.stderr)
    (case / "output.log").write_text(result.stdout + result.stderr)
    results.append({"name": name, "passed": True, "returncode": result.returncode,
                    "checker_args": args, "shallow_depth": options.get("depth", 2)})
    print(f"PASS {name}", flush=True)


run_case("added", changes={"changelog.d/201.md": fragment(201)}, expected_files=["changelog.d/201.md"], success=True)
run_case("modified", base={"changelog.d/201.md": "bad before\n"},
         changes={"changelog.d/201.md": fragment(201)}, expected_files=["changelog.d/201.md"], success=True)
run_case("invalid-citation", changes={"changelog.d/201.md": fragment(202)},
         expected_files=["changelog.d/201.md"], success=False)
run_case("removed", changes={"changelog.d/10.md": None}, expected_files=[], success=True)
run_case("readme-only", changes={"changelog.d/README.md": "documentation, not a fragment\n"}, expected_files=[], success=True)
run_case("rename-within-invalid", base={"changelog.d/201.md": fragment(201)},
         changes={"changelog.d/201.md": None, "changelog.d/202.md": fragment(201)},
         expected_files=["changelog.d/202.md"], success=False)
run_case("rename-within-corrected", base={"changelog.d/201.md": fragment(201)},
         changes={"changelog.d/201.md": None, "changelog.d/202.md": fragment(202)},
         expected_files=["changelog.d/202.md"], success=True)
run_case("rename-out", base={"changelog.d/201.md": fragment(201)},
         changes={"changelog.d/201.md": None, "docs/201.md": fragment(201)}, expected_files=[], success=True)
run_case("rename-in", base={"docs/201.md": fragment(201)},
         changes={"docs/201.md": None, "changelog.d/201.md": fragment(201)},
         expected_files=["changelog.d/201.md"], success=True)
unusual = ["changelog.d/[0-9]*.md", "changelog.d/newline\nname.md", "changelog.d/space name.md", "changelog.d/tab\tname.md", "changelog.d/unicode-가.md"]
run_case("nul-filenames", changes={name: fragment(201) for name in unusual},
         expected_files=unusual, success=False)
run_case("nested-path-still-refused", changes={"changelog.d/nested/201.md": fragment(201)},
         expected_files=["changelog.d/nested/201.md"], success=False)
run_case("upper-layer-with-moving-base", changes={"changelog.d/201.md": fragment(201)},
         advance={"changelog.d/20.md": "another malformed lower-layer fragment\n"},
         expected_files=["changelog.d/201.md"], success=True)
run_case("missing-parent-fails-closed", changes={"changelog.d/201.md": fragment(201)}, depth=1,
         expected_files=None, success=False)
run_case("dispatch-checks-all-invalid", changes={"changelog.d/201.md": fragment(201)},
         expected_files=None, success=False, dispatch=True)
run_case("dispatch-checks-all-valid", base={"changelog.d/10.md": fragment(10)},
         changes={"changelog.d/201.md": fragment(201)}, expected_files=None, success=True, dispatch=True)

manifest = {
    "run": str(RUN),
    "worktree_head": git(WORKTREE, "rev-parse", "HEAD"),
    "workflow_sha256": hashlib.sha256(WORKFLOW.read_bytes()).hexdigest(),
    "checker_sha256": hashlib.sha256(CHECKER.read_bytes()).hexdigest(),
    "results": results,
}
(RUN / "results.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
print(f"{len(results)} Git fixture cases PASS; output: {RUN}")
