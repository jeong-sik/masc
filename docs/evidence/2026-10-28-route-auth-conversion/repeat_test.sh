#!/bin/bash
# Run one test several times on two or more trees, alternating between them, in the clean
# environment of run_tests.sh, and print which cases fail in each run. A test whose failing
# cases change from run to run on the same tree is intermittent, and its failures say nothing
# about the difference between two trees.
#
#   repeat_test.sh <rounds> <test-name> <label>=<tree> [<label>=<tree> ...] [--after <test-name>...]
#
# With --after, those tests run first in the same HOME and in the order given, as they do in a
# run of run_tests.sh; only the failing cases of <test-name> are printed. Every test needs
# _build/default/test/<name>.exe in its tree. The output starts with the commit of each tree.
set -u

# A test still running after this many seconds is stopped.
TEST_TIMEOUT_S=300

[ $# -ge 3 ] || { echo "usage: repeat_test.sh <rounds> <test-name> <label>=<tree>... [--after <test-name>...]" >&2; exit 1; }
ROUNDS=$1; TEST=$2; shift 2
TREES=()
while [ $# -gt 0 ] && [ "$1" != --after ]; do TREES+=("$1"); shift; done
[ "${1:-}" = --after ] && shift
BEFORE=("$@")

run_once() { # <tree> <test> <home>
  (cd "$1" && env -i PATH="$PATH" HOME="$3" DUNE_SOURCEROOT="$1" MASC_MAIN_EIO_EXE="$1/_build/default/bin/main_eio.exe" \
     perl -e 'alarm shift; exec @ARGV' "$TEST_TIMEOUT_S" "$1/_build/default/test/$2.exe" 2>&1)
}

# Alcotest prints one line per failing case: "[FAIL]  <suite>  <number>  <name>".
failing_cases() { perl -ne 'print "$1\n" if /^(?:> |  )\[FAIL\]\s+.+?\s{2,}(\d+)\s/' | paste -sd, -; }

for pair in "${TREES[@]}"; do
  tree=$(cd "${pair#*=}" && pwd)
  echo "${pair%%=*}: $(git -C "$tree" rev-parse HEAD)"
done
echo "test: $TEST, rounds: $ROUNDS, run first in the same HOME: ${BEFORE[*]:-nothing}"

for round in $(seq 1 "$ROUNDS"); do
  for pair in "${TREES[@]}"; do
    label=${pair%%=*}; tree=$(cd "${pair#*=}" && pwd)
    home=$(mktemp -d)
    for first in ${BEFORE[@]+"${BEFORE[@]}"}; do run_once "$tree" "$first" "$home" > /dev/null; done
    cases=$(run_once "$tree" "$TEST" "$home" | failing_cases)
    echo "round $round $label: failing [$cases]"
    rm -rf "$home"
  done
done
