#!/bin/bash
# Run built test executables of one build tree directly (not through dune), in a clean
# environment, and keep what they print.
#
#   run_tests.sh <tree> <out-dir> <test-name>...
#
# The working directory is <tree>. The environment is empty but for PATH, a fresh HOME,
# DUNE_SOURCEROOT=<tree>, the variable dune sets when it runs a test (the prompt registry
# finds config/prompts through it), and MASC_MAIN_EIO_EXE=<tree>/_build/default/bin/main_eio.exe,
# which the stanza of test_server_runtime_bootstrap sets. A shell that exports MASC_*
# variables, a public MASC_HTTP_BASE_URL for one, changes what several tests answer, so none
# is passed on. Other settings of the test stanzas in test/dune (deps copied to the build
# directory, other setenv lines) are not reproduced.
#
# <tree> must already have _build/default/test/<test-name>.exe. Writes <out-dir>/<test>.txt
# (output of the test, last line "exit=<code>"), <out-dir>/results.tsv and <out-dir>/build.txt
# (commit, the number of uncommitted files under lib, bin and test, and tool versions). Run
# it once per tree.
set -u

# A test still running after this many seconds is stopped; its exit code is then 142.
TEST_TIMEOUT_S=300

[ $# -ge 3 ] || { echo "usage: run_tests.sh <tree> <out-dir> <test-name>..." >&2; exit 1; }
TREE=$(cd "$1" && pwd); OUT=$2; shift 2

mkdir -p "$OUT"
HOME_DIR=$(mktemp -d)
trap 'rm -rf "$HOME_DIR"' EXIT
{
  echo "tree_commit=$(git -C "$TREE" rev-parse HEAD)"
  echo "uncommitted_files_in_lib_bin_test=$(git -C "$TREE" status --porcelain -- lib bin test | wc -l | tr -d ' ')"
  echo "ocaml=$(ocamlfind ocamlopt -version 2>/dev/null)"
  echo "dune=$(dune --version 2>/dev/null)"
  echo "os=$(uname -sr)"
} > "$OUT/build.txt"
: > "$OUT/results.tsv"

for test in "$@"; do
  exe="$TREE/_build/default/test/$test.exe"
  [ -x "$exe" ] || { echo "missing $exe" >&2; exit 1; }
  (cd "$TREE" && env -i PATH="$PATH" HOME="$HOME_DIR" DUNE_SOURCEROOT="$TREE" MASC_MAIN_EIO_EXE="$TREE/_build/default/bin/main_eio.exe" perl -e 'alarm shift; exec @ARGV' "$TEST_TIMEOUT_S" "$exe" > "$OUT/$test.txt" 2>&1; echo "exit=$?" >> "$OUT/$test.txt")
  code=$(tail -1 "$OUT/$test.txt" | sed 's/^exit=//')
  summary=$(grep -E 'failures?!|Test Successful' "$OUT/$test.txt" | tail -1)
  printf '%s\t%s\t%s\n' "$test" "$code" "$summary" >> "$OUT/results.tsv"
done
