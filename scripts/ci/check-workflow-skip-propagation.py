#!/usr/bin/env python3
"""A skipped job must not silently skip the jobs that need it.

GitHub Actions skips a job when any job in its `needs` did not succeed,
and "skipped" counts as not succeeded, unless the job's own `if:` uses a
status function. So a job that `needs` a job which can be skipped (one
with its own `if:`, or one that needs such a job) is skipped too, while the
run as a whole still reports success.

That is how v0.44.0 was tagged and never published: #39439 added
`validate-release-entrypoint` (`if: github.event_name == 'workflow_dispatch'`)
to release.yml. `build` was guarded against its skip, but `release`
(`needs: build`, no `if:`) was not. On a tag push the skip travelled down to
`release`, and tag run 36322296436 finished green with `release` skipped.

This check reads the `jobs:` block of each workflow. Every job that needs a
skippable job must carry an `if:` containing `!cancelled()` or `always()`,
so that it decides for itself what to do with a skipped need.

It parses only the indentation shape GitHub workflows use (two spaces per
level), so it needs no third-party YAML package.

Usage:
  check-workflow-skip-propagation.py [WORKFLOW ...]   # default: release workflows
  check-workflow-skip-propagation.py --self-test
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_WORKFLOWS = (
    ".github/workflows/release.yml",
    ".github/workflows/release-build.yml",
    ".github/workflows/release-candidate.yml",
)

JOB_HEADER = re.compile(r"^  ([A-Za-z0-9_-]+):\s*(?:#.*)?$")
JOB_KEY = re.compile(r"^    ([A-Za-z0-9_-]+):\s*(.*)$")
LIST_ITEM = re.compile(r"^\s+-\s+(.+?)\s*$")
GUARD = re.compile(r"always\(\)|!\s*cancelled\(\)")
BLOCK_SCALAR = re.compile(r"^[>|][+-]?\s*$")


@dataclass
class Job:
    name: str
    line: int
    needs: list[str] = field(default_factory=list)
    condition: str | None = None


def _strip_comment(value: str) -> str:
    return re.sub(r"\s+#.*$", "", value).strip()


def _flow_list(value: str) -> list[str]:
    inner = value.strip()[1:-1]
    return [item.strip().strip("'\"") for item in inner.split(",") if item.strip()]


def parse_jobs(text: str) -> list[Job]:
    lines = text.splitlines()
    try:
        start = next(i for i, line in enumerate(lines) if re.match(r"^jobs:\s*(?:#.*)?$", line))
    except StopIteration:
        return []
    jobs: list[Job] = []
    current: Job | None = None
    i = start + 1
    while i < len(lines):
        line = lines[i]
        if line and not line.startswith(" ") and not line.startswith("#"):
            break  # next top-level key
        header = JOB_HEADER.match(line)
        if header:
            current = Job(name=header.group(1), line=i + 1)
            jobs.append(current)
            i += 1
            continue
        key = JOB_KEY.match(line)
        if current is not None and key:
            name, value = key.group(1), _strip_comment(key.group(2))
            if name == "needs":
                if value.startswith("["):
                    current.needs = _flow_list(value)
                elif value:
                    current.needs = [value.strip("'\"")]
                else:
                    j = i + 1
                    while j < len(lines) and (item := LIST_ITEM.match(lines[j])) \
                            and len(lines[j]) - len(lines[j].lstrip()) > 4:
                        current.needs.append(_strip_comment(item.group(1)).strip("'\""))
                        j += 1
                    i = j
                    continue
            elif name == "if":
                if value and not BLOCK_SCALAR.match(value):
                    current.condition = value
                else:
                    body = []
                    j = i + 1
                    while j < len(lines) and (not lines[j].strip()
                                              or len(lines[j]) - len(lines[j].lstrip()) > 4):
                        body.append(lines[j].strip())
                        j += 1
                    current.condition = " ".join(part for part in body if part)
                    i = j
                    continue
        i += 1
    return jobs


def violations(path: str, text: str) -> list[str]:
    jobs = {job.name: job for job in parse_jobs(text)}
    skippable: dict[str, bool] = {}

    def can_skip(name: str, seen: frozenset[str] = frozenset()) -> bool:
        if name in skippable:
            return skippable[name]
        job = jobs.get(name)
        if job is None or name in seen:
            return False
        result = job.condition is not None or any(
            can_skip(need, seen | {name}) for need in job.needs)
        skippable[name] = result
        return result

    found = []
    for job in jobs.values():
        if job.condition is not None and GUARD.search(job.condition):
            continue
        for need in job.needs:
            if can_skip(need):
                reason = ("has its own if:" if jobs[need].condition is not None
                          else "needs a job that can be skipped")
                found.append(
                    f"{path}:{job.line}: job '{job.name}' needs '{need}', which can be "
                    f"skipped ({need} {reason}), but '{job.name}' has no if: containing "
                    f"!cancelled() or always(); a skipped '{need}' skips '{job.name}' "
                    f"while the run still reports success")
                break
    return found


def self_test() -> int:
    cases = [
        ("unguarded job after a conditional job", """\
on: push
jobs:
  validate:
    if: ${{ github.event_name == 'workflow_dispatch' }}
    runs-on: ubuntu-latest
  build:
    needs: validate
    if: ${{ !cancelled() && needs.validate.result != 'failure' }}
    runs-on: ubuntu-latest
  release:
    needs: build
    runs-on: ubuntu-latest
""", ["release"]),
        ("guarded chain passes", """\
jobs:
  validate:
    if: github.event_name == 'workflow_dispatch'
  build:
    needs: validate
    if: ${{ !cancelled() && needs.validate.result != 'failure' }}
  release:
    needs: build
    if: ${{ !cancelled() && needs.build.result == 'success' }}
""", []),
        ("needs without any conditional job passes", """\
jobs:
  compile:
    runs-on: ubuntu-latest
  test:
    needs: compile
""", []),
        ("skip travels through an unguarded middle job", """\
jobs:
  gate:
    if: inputs.enabled
  middle:
    needs: [gate]
  last:
    needs:
      - middle   # comment
""", ["middle", "last"]),
        ("always() in a folded if counts as a guard", """\
jobs:
  a:
    if: inputs.x
  b:
    needs: [a]
    if: >-
      always() &&
      needs.a.result != 'failure'
""", []),
    ]
    failed = 0
    for label, text, expected in cases:
        got = [re.search(r"job '([^']+)'", v).group(1) for v in violations("fixture.yml", text)]
        if sorted(got) != sorted(expected):
            print(f"FAIL {label}: expected {expected}, got {got}")
            failed += 1
        else:
            print(f"ok   {label}")
    print(f"{len(cases) - failed}/{len(cases)} fixtures passed")
    return 1 if failed else 0


def main(argv: list[str]) -> int:
    if argv[1:] == ["--self-test"]:
        return self_test()
    paths = argv[1:] or list(DEFAULT_WORKFLOWS)
    found = []
    for path in paths:
        found.extend(violations(path, Path(path).read_text(encoding="utf-8")))
    for line in found:
        print(line)
    if found:
        print(f"{len(found)} job(s) would be skipped by a skipped need; add an if: with "
              f"!cancelled() or always() that states what the job does then.")
        return 1
    print(f"skip propagation: {len(paths)} workflow(s) checked, no unguarded needs")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
