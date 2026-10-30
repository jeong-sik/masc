#!/usr/bin/env bash
# Validate every Git-tracked .yml/.yaml file, including hidden configuration.
#
# This script parses repository YAML with PyYAML, aggregates parse
# failures across all files, prints one ::error annotation per failing
# file, and exits non-zero if any file failed (i.e. it does not
# fail-fast — operators get the full list of broken files in a single
# CI run).
#
# Dependency: PyYAML. The manual syntax job installs it explicitly.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

python3 - <<'PYCODE'
import os
import subprocess
import sys
import yaml
from yaml.constructor import ConstructorError


class UniqueKeyLoader(yaml.SafeLoader):
    pass


def construct_unique_mapping(loader, node, deep=False):
    seen = set()
    for key_node, _ in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in seen:
            raise ConstructorError(
                "while constructing a mapping",
                node.start_mark,
                f"found duplicate key {key!r}",
                key_node.start_mark,
            )
        seen.add(key)
    return yaml.SafeLoader.construct_mapping(loader, node, deep=deep)


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    construct_unique_mapping,
)


def gha_escape(s: str) -> str:
    """Escape a string for a GitHub Actions workflow command line.

    Workflow commands (`::error ...::message`) interpret newlines and
    `%` specially.  The official sequences are %25, %0A, %0D — applied
    in that order so the literal `%` in the input does not get
    re-escaped after being emitted as `%25`.
    """
    return s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


failed = 0
# The checked-out repository is the validation scope. NUL separation preserves
# spaces and newlines in filenames; generated dependency trees are not scanned.
paths = subprocess.check_output(["git", "ls-files", "-z", "--", "*.yml", "*.yaml"])
files = sorted(os.fsdecode(path) for path in paths.split(b"\0") if path)
for path in files:
    try:
        with open(path, encoding="utf-8") as fh:
            yaml.load(fh, Loader=UniqueKeyLoader)
    except (yaml.YAMLError, OSError, UnicodeError) as exc:
        failed += 1
        msg = gha_escape(f"YAML parse error: {exc}")
        print(f"::error file={path}::{msg}", file=sys.stderr)

if failed:
    print(f"yaml-syntax: {failed} YAML file(s) failed to parse", file=sys.stderr)
    sys.exit(1)

print(f"yaml-syntax: {len(files)} YAML file(s) parsed OK")
PYCODE
