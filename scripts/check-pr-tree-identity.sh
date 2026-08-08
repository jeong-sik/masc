#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <base-commit> <head-commit>" >&2
  exit 2
fi

base_ref=$1
head_ref=$2

if ! base_tree=$(git rev-parse --verify --end-of-options "${base_ref}^{tree}" 2>/dev/null); then
  echo "::error title=PR tree identity gate::cannot resolve base commit tree: ${base_ref}" >&2
  exit 2
fi

if ! head_tree=$(git rev-parse --verify --end-of-options "${head_ref}^{tree}" 2>/dev/null); then
  echo "::error title=PR tree identity gate::cannot resolve head commit tree: ${head_ref}" >&2
  exit 2
fi

echo "base_commit=${base_ref} base_tree=${base_tree}"
echo "head_commit=${head_ref} head_tree=${head_tree}"

if [ "$base_tree" = "$head_tree" ]; then
  echo "::error title=Same-tree no-op PR::base and head resolve to the same Git tree ${head_tree}; close this superseded PR instead of creating a no-op main commit" >&2
  exit 1
fi

echo "PR tree identity gate passed: base and head trees differ"
