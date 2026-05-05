#!/usr/bin/env bash
# Validate YAML syntax for every .github/workflows/*.yml.
#
# Why: 2026-05-05 PR #13042 added two `run: |` blocks to ci.yml that both
# contained the `\<newline>column-1-text` line-continuation pattern. PR
# #13050 fixed one of them (line 529-530) but missed the identical
# pattern in the env_knob_catalog gate (line 542-545) introduced in the
# same batch. main was a 30+ minute merge blocker until PR #13064
# collapsed the second occurrence. The miss happened because workflow
# files were not parsed at PR-time — invalid syntax silently fails the
# workflow run as "workflow-file-issue" rather than failing the PR.
#
# This script parses every workflow file with PyYAML, aggregates parse
# failures across all files, prints one ::error annotation per failing
# file, and exits non-zero if any file failed (i.e. it does not
# fail-fast — operators get the full list of broken files in a single
# CI run). Run as a PR check so the same partial-fix shape cannot
# reach main again.
#
# Dependency: PyYAML. The .github/workflows/fundamental-check.yml
# job that invokes this script installs it explicitly via
# `python -m pip install pyyaml` so the gate does not silently rely
# on whatever happens to be preinstalled on ubuntu-latest at the
# moment.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

shopt -s nullglob
files=(.github/workflows/*.yml .github/workflows/*.yaml)
shopt -u nullglob

if [[ ${#files[@]} -eq 0 ]]; then
  echo "yaml-syntax: no workflow files found"
  exit 0
fi

python3 - "${files[@]}" <<'PY'
import sys
import yaml


def gha_escape(s: str) -> str:
    """Escape a string for a GitHub Actions workflow command line.

    Workflow commands (`::error ...::message`) interpret newlines and
    `%` specially.  The official sequences are %25, %0A, %0D — applied
    in that order so the literal `%` in the input does not get
    re-escaped after being emitted as `%25`.
    """
    return s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


failed = 0
for path in sys.argv[1:]:
    try:
        with open(path) as fh:
            yaml.safe_load(fh)
    except yaml.YAMLError as exc:
        failed += 1
        msg = gha_escape(f"YAML parse error: {exc}")
        print(f"::error file={path}::{msg}", file=sys.stderr)

if failed:
    print(f"yaml-syntax: {failed} workflow file(s) failed to parse", file=sys.stderr)
    sys.exit(1)

print(f"yaml-syntax: {len(sys.argv) - 1} workflow file(s) parsed OK")
PY
