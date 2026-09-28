#!/usr/bin/env bash
# A workflow must name a stable Ubuntu runner image. Scan active YAML text,
# including matrix values that reach runs-on indirectly; ignore comments.
#
# The scan parses each workflow with PyYAML and walks its node tree, so a `#`
# inside a quoted scalar is data, not a comment. A raw-text scan that strips
# from the first `#` misses an active `ubuntu-latest` on the same line as a
# quoted `#` (issue #39700).
#
# Usage: no-ubuntu-latest-runner.sh [--self-test] [FILE...]
set -euo pipefail

scan() {
  python3 - "$@" <<'PY'
import sys
import yaml

LABEL = "ubuntu-latest"


def walk(node, out):
    if isinstance(node, yaml.ScalarNode):
        if LABEL in str(node.value):
            out.append((node.start_mark.line + 1, str(node.value)))
    elif isinstance(node, yaml.SequenceNode):
        for child in node.value:
            walk(child, out)
    elif isinstance(node, yaml.MappingNode):
        for key, value in node.value:
            walk(key, out)
            walk(value, out)


hits = []
for path in sys.argv[1:]:
    try:
        with open(path) as fh:
            root = yaml.compose(fh)
    except yaml.YAMLError as exc:
        print(f"no-ubuntu-latest-runner: {path}: YAML parse error: {exc}", file=sys.stderr)
        sys.exit(1)
    if root is None:
        continue
    found = []
    walk(root, found)
    for line, value in found:
        hits.append(f"{path}:{line}:{value}")

if hits:
    print("no-ubuntu-latest-runner: pin Ubuntu runners to an explicit version:", file=sys.stderr)
    for hit in hits:
        print(hit, file=sys.stderr)
    sys.exit(1)
PY
}

if [[ "${1:-}" == "--self-test" ]]; then
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/no-ubuntu-latest-selftest.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT

  # 1) An active matrix value after a quoted `#` on the same line. The `#` is
  #    data, not a comment, so the label must still be caught (issue #39700).
  cat >"$tmp/quoted-hash.yml" <<'YAML'
name: runner-pin-repro
on: push
jobs:
  build:
    strategy: { matrix: { note: "#", os: [ubuntu-latest] } }
    runs-on: ${{ matrix.os }}
    steps:
      - run: echo ok
YAML

  # 2) The label only in a comment: not active text, must pass.
  cat >"$tmp/comment-only.yml" <<'YAML'
name: comment-only
on: push
jobs:
  build:
    runs-on: ubuntu-24.04  # was ubuntu-latest
    steps:
      - run: echo ok
YAML

  # 3) A pinned runner: must pass.
  cat >"$tmp/pinned.yml" <<'YAML'
name: pinned
on: push
jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - run: echo ok
YAML

  fail=0
  if scan "$tmp/quoted-hash.yml" >/dev/null 2>&1; then
    echo "no-ubuntu-latest-runner self-test FAIL: quoted-hash fixture was not caught" >&2
    fail=1
  fi
  if ! scan "$tmp/comment-only.yml" >/dev/null 2>&1; then
    echo "no-ubuntu-latest-runner self-test FAIL: comment-only fixture was flagged" >&2
    fail=1
  fi
  if ! scan "$tmp/pinned.yml" >/dev/null 2>&1; then
    echo "no-ubuntu-latest-runner self-test FAIL: pinned fixture was flagged" >&2
    fail=1
  fi
  if (( fail )); then
    exit 1
  fi
  echo "no-ubuntu-latest-runner self-test OK"
  exit 0
fi

if (( $# > 0 )); then
  files=("$@")
else
  cd "$(git rev-parse --show-toplevel)"
  shopt -s nullglob
  files=(.github/workflows/*.yml .github/workflows/*.yaml)
  shopt -u nullglob
  if (( ${#files[@]} == 0 )); then
    echo "no-ubuntu-latest-runner: no workflow files found" >&2
    exit 1
  fi
fi

scan "${files[@]}"
printf 'no-ubuntu-latest-runner: %d workflow files checked\n' "${#files[@]}"
