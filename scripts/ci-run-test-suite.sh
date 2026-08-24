#!/usr/bin/env bash
# Run every test suite Dune knows about and compare what fails against
# test/ci-known-failures.txt.
#
# CI used to name the suites it wanted, 894 of them across 26 workflow steps
# and a 1,000-line script. A suite missing from that list was not run and
# nothing said so. Here the default is to run, and the list names what is
# broken instead of what works.
set -uo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root" || exit 2

known_file="test/ci-known-failures.txt"
# One budget for the whole suite. The job timeout above this is the last
# boundary; this one exists so a hang prints its diagnostics first.
deadline="${MASC_TEST_SUITE_DEADLINE:-5400}"
log="${RUNNER_TEMP:-/tmp}/test-suite.log"

if [ ! -f "$known_file" ]; then
  echo "[test-suite] FAIL - $known_file is missing"
  exit 2
fi

echo "[test-suite] dune build @test/runtest (deadline ${deadline}s)"
started=$(date +%s)
timeout "$deadline" opam exec -- dune build --root . @test/runtest > "$log" 2>&1
rc=$?
echo "[test-suite] finished in $(( $(date +%s) - started ))s with exit ${rc}"

if [ "$rc" = 124 ]; then
  echo "[test-suite] FAIL - the suite did not finish inside ${deadline}s"
  echo
  tail -60 "$log"
  exit 2
fi

# A failed suite prints a header naming the stanza that declared it, then the
# stanza line itself. Both shapes carry the name on that second line:
#   File "test/dune", line 1089, ...        /  1089 |   test_fs_compat
#   File "test/stanzas/test_x.inc", line 7  /     7 |  (name test_x)
awk '
  /^File "test\/(dune|stanzas\/[a-z0-9_]+\.inc)", line/ { want = 1; next }
  want { if (match($0, /test_[a-z0-9_]+/)) print substr($0, RSTART, RLENGTH); want = 0 }
' "$log" | sort -u > "${RUNNER_TEMP:-/tmp}/failed.txt"

sed 's/#.*//' "$known_file" | tr -d '[:blank:]' | grep -v '^$' | sort -u \
  > "${RUNNER_TEMP:-/tmp}/known.txt"

failed_count=$(wc -l < "${RUNNER_TEMP:-/tmp}/failed.txt" | tr -d ' ')
known_count=$(wc -l < "${RUNNER_TEMP:-/tmp}/known.txt" | tr -d ' ')

# Errors Dune reported that no stanza header explained: a compile failure, a
# missing dependency, an alias that resolves to nothing. Attributing zero of
# them to a suite is what makes an unexplained red look like a green.
headers=$(grep -c '^File "' "$log" || true)
if [ "$rc" != 0 ] && [ "$failed_count" -eq 0 ]; then
  echo "[test-suite] FAIL - dune exited ${rc} and no failure named a suite"
  echo
  tail -60 "$log"
  exit 2
fi

status=0
new="$(comm -23 "${RUNNER_TEMP:-/tmp}/failed.txt" "${RUNNER_TEMP:-/tmp}/known.txt")"
if [ -n "$new" ]; then
  status=1
  echo "[test-suite] FAIL - suites broke that $known_file does not list"
  echo
  printf '%s\n' "$new" | sed 's/^/  - /'
  echo
  echo "Fix the suite. Adding it to $known_file records the break as normal,"
  echo "which is how the last six spent a month unnoticed."
  echo
  for name in $new; do
    echo "--- $name ---"
    awk -v n="$name" '$0 ~ n {p = 1} p && /^$/ {exit} p' "$log" | head -25
  done
fi

fixed="$(comm -13 "${RUNNER_TEMP:-/tmp}/failed.txt" "${RUNNER_TEMP:-/tmp}/known.txt")"
if [ -n "$fixed" ]; then
  status=1
  echo "[test-suite] FAIL - $known_file lists suites that now pass"
  echo
  printf '%s\n' "$fixed" | sed 's/^/  - /'
  echo
  echo "Take these lines out of $known_file. Leaving them is slack: the next"
  echo "suite to break can take the empty slot and still read as expected."
fi

if [ "$status" = 0 ]; then
  echo "[test-suite] OK - ${failed_count} suites failed, all ${known_count} known"
  echo "[test-suite] dune reported ${headers} stanza headers"
fi
exit "$status"
