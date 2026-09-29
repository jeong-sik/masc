#!/usr/bin/env bash
# A workflow must name a stable Ubuntu runner image. Scan the values that
# actually reach `runs-on`: a literal `runs-on`, and the matrix values a
# `runs-on: ${{ matrix.<name> }}` expression references. Everything else —
# step bodies, `run: |` shell comments, unrelated matrix keys — is not a
# runner label and is ignored.
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
import re
import sys
import yaml

LABEL = "ubuntu-latest"
MATRIX_REF = re.compile(r"matrix\.([A-Za-z_][A-Za-z0-9_-]*)")


def mapping_get(node, key):
    if not isinstance(node, yaml.MappingNode):
        return None
    for k, v in node.value:
        if isinstance(k, yaml.ScalarNode) and k.value == key:
            return v
    return None


def iter_scalars(node):
    if isinstance(node, yaml.ScalarNode):
        yield node
    elif isinstance(node, yaml.SequenceNode):
        for child in node.value:
            if isinstance(child, yaml.ScalarNode):
                yield child


def matrix_values(matrix, name):
    """(line, value) for matrix.<name>, including matrix.include entries."""
    out = []
    if not isinstance(matrix, yaml.MappingNode):
        return out
    for k, v in matrix.value:
        if not isinstance(k, yaml.ScalarNode):
            continue
        if k.value == name:
            for item in iter_scalars(v):
                out.append((item.start_mark.line + 1, str(item.value)))
        elif k.value == "include" and isinstance(v, yaml.SequenceNode):
            for entry in v.value:
                if not isinstance(entry, yaml.MappingNode):
                    continue
                for ek, ev in entry.value:
                    if (
                        isinstance(ek, yaml.ScalarNode)
                        and ek.value == name
                        and isinstance(ev, yaml.ScalarNode)
                    ):
                        out.append((ev.start_mark.line + 1, str(ev.value)))
    return out


def check_label_node(value_node, matrix, path, hits):
    text = str(value_node.value)
    refs = MATRIX_REF.findall(text)
    if refs:
        for name in refs:
            for line, value in matrix_values(matrix, name):
                if LABEL in value:
                    hits.append(f"{path}:{line}:{value}")
    elif LABEL in text:
        hits.append(f"{path}:{value_node.start_mark.line + 1}:{text}")


def check_job(job, path, hits):
    runs_on = mapping_get(job, "runs-on")
    if runs_on is None:
        return
    matrix = mapping_get(mapping_get(job, "strategy"), "matrix")
    if isinstance(runs_on, yaml.MappingNode):
        # GitHub's mapping form names the image under `labels`; `group` selects
        # a runner group, not an image, so only `labels` is a runner label.
        labels = mapping_get(runs_on, "labels")
        for value_node in iter_scalars(labels):
            check_label_node(value_node, matrix, path, hits)
        return
    for value_node in iter_scalars(runs_on):
        check_label_node(value_node, matrix, path, hits)


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
    jobs = mapping_get(root, "jobs")
    if isinstance(jobs, yaml.MappingNode):
        for _job_name, job in jobs.value:
            check_job(job, path, hits)

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

  # 4) The label only in a shell comment inside a `run: |` body: not a runner
  #    label, must pass (masc-pro-builder P2 on #39757).
  cat >"$tmp/shell-comment.yml" <<'YAML'
name: shell-comment
on: push
jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - run: |
          # ubuntu-latest is banned here
          echo ok
YAML

  # 5) The label in a matrix key that `runs-on` does not reference: not a
  #    runner label, must pass.
  cat >"$tmp/unreferenced-matrix.yml" <<'YAML'
name: unreferenced-matrix
on: push
jobs:
  build:
    strategy:
      matrix:
        note: [ubuntu-latest]
        os: [ubuntu-24.04]
    runs-on: ${{ matrix.os }}
    steps:
      - run: echo ok
YAML

  # 6) The mapping form of runs-on: `labels` names the runner image, so the
  #    label must be caught (masc-pro-builder P2 on #39757).
  cat >"$tmp/mapping-labels.yml" <<'YAML'
name: mapping-labels
on: push
jobs:
  build:
    runs-on:
      group: my-group
      labels: [ubuntu-latest]
    steps:
      - run: echo ok
YAML

  # 7) The mapping form with a pinned label: must pass.
  cat >"$tmp/mapping-pinned.yml" <<'YAML'
name: mapping-pinned
on: push
jobs:
  build:
    runs-on:
      group: my-group
      labels: [ubuntu-24.04]
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
  if ! scan "$tmp/shell-comment.yml" >/dev/null 2>&1; then
    echo "no-ubuntu-latest-runner self-test FAIL: shell-comment fixture was flagged" >&2
    fail=1
  fi
  if ! scan "$tmp/unreferenced-matrix.yml" >/dev/null 2>&1; then
    echo "no-ubuntu-latest-runner self-test FAIL: unreferenced-matrix fixture was flagged" >&2
    fail=1
  fi
  if scan "$tmp/mapping-labels.yml" >/dev/null 2>&1; then
    echo "no-ubuntu-latest-runner self-test FAIL: mapping-labels fixture was not caught" >&2
    fail=1
  fi
  if ! scan "$tmp/mapping-pinned.yml" >/dev/null 2>&1; then
    echo "no-ubuntu-latest-runner self-test FAIL: mapping-pinned fixture was flagged" >&2
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
