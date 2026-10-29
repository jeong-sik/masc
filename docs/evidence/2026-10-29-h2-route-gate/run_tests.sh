#!/bin/bash
# Runs test executables outside dune in a clean environment (env -i, fresh HOME, DUNE_SOURCEROOT).
#
#   run_tests.sh <out-dir> <test name> ...
#
# Build the executables first: dune build --root . ./test/<name>.exe
# The shell's own MASC_* variables change what several tests answer, so none are passed on.
set -u
W=$(git rev-parse --show-toplevel) || exit 1
OUT=$1; shift
mkdir -p "$OUT"
for t in "$@"; do
  home=$(mktemp -d)
  ( cd "$W/_build/default/test" && env -i PATH="$PATH" HOME="$home" DUNE_SOURCEROOT="$W" perl -e 'alarm shift; exec @ARGV' 900 "./$t.exe" ) > "$OUT/$t.txt" 2>&1
  code=$?
  summary=$(grep -E 'Test Successful|[0-9]+ failures?!' "$OUT/$t.txt" | tail -1)
  echo "$t exit=$code $summary"
  rm -rf "$home"
done
