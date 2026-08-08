#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
gate="${script_dir}/check-pr-tree-identity.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

git -C "$fixture" init --quiet --initial-branch=fixture
mkdir -p "${fixture}/hooks-disabled"
git -C "$fixture" config core.hooksPath "${fixture}/hooks-disabled"
git -C "$fixture" config user.name "tree-gate-test"
git -C "$fixture" config user.email "tree-gate-test@example.invalid"

printf 'base\n' >"${fixture}/value.txt"
git -C "$fixture" add value.txt
git -C "$fixture" commit --quiet -m base
base_commit=$(git -C "$fixture" rev-parse HEAD)

git -C "$fixture" commit --quiet --allow-empty -m same-tree
same_tree_commit=$(git -C "$fixture" rev-parse HEAD)
if (cd "$fixture" && bash "$gate" "$base_commit" "$same_tree_commit") >/dev/null 2>&1; then
  echo "expected same-tree commits to fail" >&2
  exit 1
fi

printf 'changed\n' >"${fixture}/value.txt"
git -C "$fixture" add value.txt
git -C "$fixture" commit --quiet -m changed-tree
changed_tree_commit=$(git -C "$fixture" rev-parse HEAD)
(cd "$fixture" && bash "$gate" "$same_tree_commit" "$changed_tree_commit") >/dev/null

if (cd "$fixture" && bash "$gate" missing-ref "$changed_tree_commit") >/dev/null 2>&1; then
  echo "expected an unresolved commit to fail closed" >&2
  exit 1
fi

echo "PR tree identity gate tests passed"
