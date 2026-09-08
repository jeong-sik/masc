#!/bin/sh
set -eu

# Consumer check for the committed tool parity baselines (task-1460).
#
# Reruns bin/tool_parity_generator.exe against config/tools/*.toml inside a
# scratch tree and byte-compares the regenerated artifacts with the committed
# test/golden/tool_parity_*.txt baselines. A config/tools edit that is not
# followed by a baseline regeneration fails here instead of drifting
# silently.
#
# The real test/golden is only ever read. The generator's output directory
# is CWD-relative ("test/golden"), so running it with the scratch tree as
# CWD keeps every write inside the scratch tree; the committed baselines are
# never touched.
#
# Invoked from the root dune rule (alias runtest) with the generator binary
# as the only argument, from the workspace-root mirror (config/tools and
# test/golden must exist relative to the current directory).

if [ "$#" -ne 1 ]; then
  echo "usage: check-tool-parity-golden.sh <path/to/tool_parity_generator.exe>" >&2
  exit 2
fi

generator=$1

# dune expands %{exe:...} to a _build-relative path; make it absolute before
# changing directory into the scratch tree.
case "$generator" in
  /*) ;;
  *) generator=$PWD/$generator ;;
esac

if [ ! -d config/tools ] || [ ! -d test/golden ]; then
  echo "check-tool-parity-golden: run from the workspace root (config/tools and test/golden must exist)" >&2
  exit 2
fi

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT INT TERM

mkdir -p "$scratch/config/tools" "$scratch/test/golden"
cp config/tools/*.toml "$scratch/config/tools/"

if ! (cd "$scratch" && "$generator" > generator.log 2>&1); then
  echo "tool parity generator failed inside the scratch tree:" >&2
  cat "$scratch/generator.log" >&2
  exit 1
fi

status=0
for name in description params visibility availability; do
  baseline=test/golden/tool_parity_$name.txt
  regenerated=$scratch/test/golden/tool_parity_$name.txt
  if [ ! -f "$regenerated" ]; then
    echo "tool parity baseline drift: regenerated output missing: $regenerated" >&2
    status=1
  elif ! cmp -s "$baseline" "$regenerated"; then
    echo "tool parity baseline drift: $baseline differs from regenerated output" >&2
    diff -u "$baseline" "$regenerated" | head -40 >&2 || true
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  echo "Regenerate with: dune build @regen_tool_parity_artifacts, then commit test/golden/tool_parity_*.txt" >&2
  exit 1
fi

echo "tool parity baselines match regenerated output (4 files)"