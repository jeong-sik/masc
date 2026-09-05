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

# The root alias, which is what `dune test` runs. The lane used to build
# @test/runtest, the test/ subtree only: the 41 (tests ...) stanzas in
# packages/agent_core/test, the ten in lib/exec/test and the tools/ suites
# had no lane at all while the changelog called this the full suite.
alias_target="@runtest"

# The header dune prints before a failure it can locate:
#   File "test/dune", line 1089, characters 2-16:
#   File "test/dune", lines 2961-2970, characters 0-202:
#   File "test/test_x.ml", line 12, characters 4-10:
# The quoted source lines after it each start with the line number and a bar.
header_re='^File "[^"]+", lines? [0-9]+(-[0-9]+)?(, characters [0-9]+-[0-9]+)?:$'

# One line per header in the log: the suite it resolves to, a tab, the header
# itself; "-" when no suite could be read.
#
# Where the name sits depends on the stanza:
#   File "test/dune", line 1089, characters 2-16:    /  1089 |   test_fs_compat
#   File "test/x/dune", line 6, characters 19-38:    /     6 | (names test_a test_b ...
#   File "test/stanzas/test_x.inc", line 7, ...      /     7 |  (name test_x)
#   File "test/dune", lines 2961-2970, ...           /  2961 | (rule
#                                                    /  2962 |  (alias runtest-x)
# For a (test) or (tests) stanza dune points the header at the one name atom
# whose suite failed, so that atom is read by its character range first: on
# `(names test_a test_b)` the first test_ word is test_a whichever one broke,
# and a break in test_b would be booked against test_a. A (rule) stanza spans
# lines and names its suite in an alias; the last resort is the first test_
# word in the quote. A header for a .ml file is a compile error and names no
# suite. Headers used to be read only from test/dune and test/stanzas/*.inc,
# so a failure in any of the 18 test/<dir>/dune files or in packages/ was
# dropped whenever another suite also failed; now every header is listed and
# the caller refuses a run in which one names no suite.
attribute_failures() {
  awk -v header_re="$header_re" '
    function flush() {
      if (header != "") printf "%s\t%s\n", (name == "" ? "-" : name), header
      header = ""; name = ""; first = 0
    }
    $0 ~ header_re {
      flush()
      header = $0
      dune_file = ($0 ~ /^File "([^"]*\/)?dune", / || $0 ~ /^File "[^"]*\.inc", /)
      from = -1; to = -1
      if (dune_file && match($0, /line [0-9]+, characters [0-9]+-[0-9]+:$/)) {
        range = substr($0, RSTART, RLENGTH)
        sub(/.*characters /, "", range); sub(/:$/, "", range)
        split(range, cols, "-"); from = cols[1] + 0; to = cols[2] + 0
      }
      first = 1
      next
    }
    header == "" { next }
    $0 !~ /^ *[0-9]+ \|/ { flush(); next }
    name != "" { next }
    first && from >= 0 {
      src = substr($0, index($0, "| ") + 2)
      atom = substr(src, from + 1, to - from)
      if (atom ~ /^[A-Za-z0-9_][A-Za-z0-9_.-]*$/) { name = atom; next }
    }
    { first = 0 }
    !dune_file { next }
    match($0, /\(alias +runtest-[A-Za-z0-9_-]+/) {
      name = substr($0, RSTART, RLENGTH); sub(/.*runtest-/, "", name); next
    }
    match($0, /test_[a-z0-9_]+/) { name = substr($0, RSTART, RLENGTH) }
    END { flush() }
  ' "$1"
}

extract_failed_names() {
  attribute_failures "$1" | awk -F'\t' '$1 != "-" { print $1 }'
}

# "<headers> <attributed>" for an attribution listing.
count_attribution() {
  awk -F'\t' '{ headers++ } $1 != "-" { named++ } END { print headers + 0, named + 0 }' "$1"
}

# The log from one header line up to the next header: the quoted stanza, the
# command dune ran, and everything the suite printed, including Alcotest's
# case name and the assertion after the blank line that follows its run ID.
print_block_from_header() {
  awk -v h="$1" -v header_re="$header_re" '
    printing && $0 ~ header_re { exit }
    !printing && $0 == h { printing = 1 }
    printing
  ' "$2"
}

print_failure_block() {
  local name="$1"
  local source_log="$2"
  local header
  header="$(attribute_failures "$source_log" \
    | awk -F'\t' -v n="$name" '$1 == n { print $2; exit }')"
  [ -n "$header" ] && print_block_from_header "$header" "$source_log"
}

# "<name> <elapsed>" for each process in process group $1 that is a built
# executable or a python suite file, read from `ps -o pgid=,etime=,args=`
# lines on stdin. Dune runs a suite as ./test_x.exe inside its sandbox, so
# argv[0] names it; the (rule) suites driven by python show their test file;
# a server binary a suite spawned is listed under its own name. The group is
# dune's, so an executable that happens to run elsewhere on the host is not
# reported as a suite.
name_suite_processes() {
  awk -v pgid="$1" '
    $1 != pgid { next }
    { name = "" }
    $3 ~ /\.exe$/ { name = $3; sub(/.*\//, "", name); sub(/\.exe$/, "", name) }
    name == "" && match($0, /test_[a-z0-9_]+\.py/) { name = substr($0, RSTART, RLENGTH - 3) }
    name != "" { print name " " $2 }'
}

suites_running_now() {
  ps -axo pgid=,etime=,args= | name_suite_processes "$1"
}

self_test() {
  local exact_block
  local longer_block
  fixture_log="$(mktemp "${TMPDIR:-/tmp}/masc-test-suite-self-test.XXXXXX")"
  trap 'rm -f "$fixture_log"' EXIT

  cat > "$fixture_log" <<'EOF'
File "test/dune", line 10, characters 0-20:
10 |  (name test_ci_failure_output_extra)
This run has ID `EXTRA'.

  [FAIL]        wrong group          0   longer suite name.
ASSERT this belongs only to the longer suite name
File "test/stanzas/test_ci_failure_output.inc", line 2, characters 1-40:
2 |  (name test_ci_failure_output)
This run has ID `EXACT'.

  [FAIL]        exact group          7   exact failing case.
ASSERT exact assertion survived the blank line
EOF

  exact_block="$(print_failure_block test_ci_failure_output "$fixture_log")"
  longer_block="$(print_failure_block test_ci_failure_output_extra "$fixture_log")"

  printf '%s\n' "$exact_block" | grep -Fq '[FAIL]        exact group          7   exact failing case.' \
    || { echo "[test-suite] self-test FAIL - exact case is missing" >&2; exit 1; }
  printf '%s\n' "$exact_block" | grep -Fq 'ASSERT exact assertion survived the blank line' \
    || { echo "[test-suite] self-test FAIL - assertion after blank line is missing" >&2; exit 1; }
  if printf '%s\n' "$exact_block" | grep -Fq 'longer suite name'; then
    echo "[test-suite] self-test FAIL - prefix suite leaked into exact block" >&2
    exit 1
  fi
  printf '%s\n' "$longer_block" | grep -Fq 'ASSERT this belongs only to the longer suite name' \
    || { echo "[test-suite] self-test FAIL - prefix suite block is missing" >&2; exit 1; }
  if printf '%s\n' "$longer_block" | grep -Fq 'exact failing case'; then
    echo "[test-suite] self-test FAIL - exact suite leaked into prefix block" >&2
    exit 1
  fi

  echo "[test-suite] self-test OK - blank line and prefix collision"

  rule_log="$(mktemp "${TMPDIR:-/tmp}/masc-test-suite-rule.XXXXXX")"
  cat > "$rule_log" <<'EOF'
File "test/dune", lines 2961-2970, characters 0-202:
2961 | (rule
2962 |  (alias runtest-test_tui_keyboard_input)
2963 |  (deps
2964 |   test_tui_keyboard_input.py
2965 |   ../bin/masc_tui.exe)
2966 |  (action
2967 |   (run
2968 |    python3
2969 |    %{dep:test_tui_keyboard_input.py}
2970 |    %{dep:../bin/masc_tui.exe})))
Traceback (most recent call last):
AssertionError: a scenario the gate could not name
File "test/dune", lines 1449-1460, characters 0-180:
1449 | (rule
1450 |  (alias runtest-dashboard-http-behavior-contracts)
1451 |  (deps a b))
Command exited with code 1.
File "test/stanzas/test_keeper_toml.inc", line 2, characters 1-40:
2 |  (name test_keeper_toml)

  [FAIL]        toml          3   a named suite still reads.
EOF

  names="$(extract_failed_names "$rule_log" | sort -u | tr '\n' ' ')"
  [ "$names" = "dashboard-http-behavior-contracts test_keeper_toml test_tui_keyboard_input " ] \
    || { echo "[test-suite] self-test FAIL - rule-declared suites are unnamed: $names" >&2
         rm -f "$rule_log"; exit 1; }

  printf '%s\n' "$(print_failure_block test_tui_keyboard_input "$rule_log")" \
    | grep -Fq 'AssertionError: a scenario the gate could not name' \
    || { echo "[test-suite] self-test FAIL - a rule's own output is missing" >&2
         rm -f "$rule_log"; exit 1; }

  if printf '%s\n' "$(print_failure_block test_tui_keyboard_input "$rule_log")" \
     | grep -Fq 'a named suite still reads'; then
    echo "[test-suite] self-test FAIL - a later suite leaked into the rule block" >&2
    rm -f "$rule_log"; exit 1
  fi

  rm -f "$rule_log"
  echo "[test-suite] self-test OK - a (rule ...) stanza names its suite"

  # Headers outside test/dune: a test/<dir>/dune file, packages/, a one-line
  # (names ...) list where the second name failed, and a name without the
  # test_ prefix. The character range, not the first test_ word, picks the
  # suite.
  subdir_log="$(mktemp "${TMPDIR:-/tmp}/masc-test-suite-subdir.XXXXXX")"
  cat > "$subdir_log" <<'EOF'
File "test/keeper_event_queue/dune", line 2, characters 7-30:
2 |  (name test_keeper_event_queue)
  [FAIL]        queue          1   a subdirectory suite.
File "packages/agent_core/test/dune", line 71, characters 2-17:
71 |   test_agent_race
  [FAIL]        race           0   a packages suite.
File "test/fusion_core/dune", line 6, characters 19-38:
6 | (names test_fusion test_fusion_harness test_fusion_run_registry
  [FAIL]        harness        2   the second name on the line.
File "tools/tlc_test_gen/sample_outputs/dune", line 38, characters 26-46:
38 |  (names sample_inv_runner nested_sample_runner)
  [FAIL]        nested         0   a name without the test_ prefix.
EOF

  names="$(extract_failed_names "$subdir_log" | tr '\n' ' ')"
  [ "$names" = "test_keeper_event_queue test_agent_race test_fusion_harness nested_sample_runner " ] \
    || { echo "[test-suite] self-test FAIL - headers outside test/dune are misread: $names" >&2
         rm -f "$subdir_log"; exit 1; }

  printf '%s\n' "$(print_failure_block test_fusion_harness "$subdir_log")" \
    | grep -Fq 'the second name on the line' \
    || { echo "[test-suite] self-test FAIL - the block for a column-picked name is missing" >&2
         rm -f "$subdir_log"; exit 1; }

  rm -f "$subdir_log"
  echo "[test-suite] self-test OK - a header outside test/dune names its suite"

  # A compile error prints a header for the .ml file and names no suite. The
  # count has to show the gap, or the run reads as its known failures only.
  gap_log="$(mktemp "${TMPDIR:-/tmp}/masc-test-suite-gap.XXXXXX")"
  cat > "$gap_log" <<'EOF'
File "test/test_broken_module.ml", line 3, characters 8-21:
3 | let x = missing_value
Error: Unbound value missing_value
File "test/stanzas/test_keeper_toml.inc", line 2, characters 1-40:
2 |  (name test_keeper_toml)
  [FAIL]        toml          3   a named suite still reads.
EOF

  gap_tsv="$(mktemp "${TMPDIR:-/tmp}/masc-test-suite-gap-tsv.XXXXXX")"
  attribute_failures "$gap_log" > "$gap_tsv"
  counts="$(count_attribution "$gap_tsv")"
  [ "$counts" = "2 1" ] \
    || { echo "[test-suite] self-test FAIL - expected 2 headers 1 attributed, got: $counts" >&2
         rm -f "$gap_log" "$gap_tsv"; exit 1; }
  unattributed="$(awk -F'\t' '$1 == "-" { print $2 }' "$gap_tsv")"
  [ "$unattributed" = 'File "test/test_broken_module.ml", line 3, characters 8-21:' ] \
    || { echo "[test-suite] self-test FAIL - the compile error header is not the unattributed one: $unattributed" >&2
         rm -f "$gap_log" "$gap_tsv"; exit 1; }
  printf '%s\n' "$(print_block_from_header "$unattributed" "$gap_log")" \
    | grep -Fq 'Error: Unbound value missing_value' \
    || { echo "[test-suite] self-test FAIL - the unattributed block lost its error line" >&2
         rm -f "$gap_log" "$gap_tsv"; exit 1; }

  rm -f "$gap_log" "$gap_tsv"
  echo "[test-suite] self-test OK - a header that names no suite is counted"

  # What the deadline snapshot reads from ps: in dune's process group a
  # dune-run suite, a python rule and a server binary a suite spawned; not a
  # shell in that group, and not an executable in another group.
  running="$(printf '%s\n' \
      '4242    01:15:02 ./test_keeper_owner.exe' \
      '4242       05:00 python3 /home/r/w/test/test_tui_keyboard_input.py --pty' \
      '4242       00:02 bash -c sleep 3' \
      '4242    00:00:40 /home/r/w/_build/default/bin/masc_server.exe --port 1' \
      '   7 03-11:36:59 /Applications/masc/masc_tui.exe' \
    | name_suite_processes 4242 | tr '\n' ';')"
  [ "$running" = "test_keeper_owner 01:15:02;test_tui_keyboard_input 05:00;masc_server 00:00:40;" ] \
    || { echo "[test-suite] self-test FAIL - the deadline snapshot misnames processes: $running" >&2
         exit 1; }
  echo "[test-suite] self-test OK - the deadline snapshot names suite processes"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit 0
fi

known_file="test/ci-known-failures.txt"
# One budget for the whole suite. The job timeout above this is the last
# boundary; this one exists so a hang prints its diagnostics first.
deadline="${MASC_TEST_SUITE_DEADLINE:-5400}"
tmp="${RUNNER_TEMP:-/tmp}"
log="$tmp/test-suite.log"
running_at_deadline="$tmp/test-suite-running-at-deadline.txt"

if [ ! -f "$known_file" ]; then
  echo "[test-suite] FAIL - $known_file is missing"
  exit 2
fi

# Dune is supervised here rather than under timeout(1) so that the deadline
# can list the suites still alive before anything is killed. The log cannot
# supply that: dune holds a suite's output until the suite exits, so the log
# tail names the last suite that finished, not the one that hung. In run
# 33916791821 (2026-09-04) the tail ended with output stamped 20:49 and the
# deadline fell at 22:04, with nothing in between. At the deadline the
# snapshot is taken, then dune's process group gets the TERM timeout would
# have sent, KILL after a grace period, and rc is 124 as before.
run_suite_under_deadline() {
  set -m
  opam exec -- dune build --root . "$alias_target" > "$log" 2>&1 &
  local dune_pid=$!
  set +m
  local exited
  local grace
  rc=""
  : > "$running_at_deadline"
  while kill -0 "$dune_pid" 2>/dev/null; do
    if [ $(( $(date +%s) - started )) -ge "$deadline" ]; then
      suites_running_now "$dune_pid" > "$running_at_deadline"
      kill -TERM -- "-$dune_pid" 2>/dev/null
      grace=30
      while [ "$grace" -gt 0 ] && kill -0 "$dune_pid" 2>/dev/null; do
        sleep 1
        grace=$((grace - 1))
      done
      kill -KILL -- "-$dune_pid" 2>/dev/null
      rc=124
      break
    fi
    sleep 5
  done
  wait "$dune_pid"
  exited=$?
  [ -n "$rc" ] || rc="$exited"
}

echo "[test-suite] dune build $alias_target (deadline ${deadline}s)"
started=$(date +%s)
run_suite_under_deadline
echo "[test-suite] finished in $(( $(date +%s) - started ))s with exit ${rc}"

if [ "$rc" = 124 ]; then
  echo "[test-suite] FAIL - the suite did not finish inside ${deadline}s"
  if [ -s "$running_at_deadline" ]; then
    echo "[test-suite] running at deadline (name, elapsed):"
    sed 's/^/  - /' "$running_at_deadline"
  else
    echo "[test-suite] running at deadline: no suite executable was alive;" \
         "dune was still building or linking, or the hang is not a suite process"
  fi
  echo
  tail -60 "$log"
  exit 2
fi

attribute_failures "$log" > "$tmp/attributed.tsv"
awk -F'\t' '$1 != "-" { print $1 }' "$tmp/attributed.tsv" | sort -u > "$tmp/failed.txt"

sed 's/#.*//' "$known_file" | tr -d '[:blank:]' | grep -v '^$' | sort -u \
  > "$tmp/known.txt"

failed_count=$(wc -l < "$tmp/failed.txt" | tr -d ' ')
known_count=$(wc -l < "$tmp/known.txt" | tr -d ' ')
read -r header_count attributed_count < <(count_attribution "$tmp/attributed.tsv")

# Errors Dune reported without a stanza header: an alias that resolves to
# nothing, a dune that died before printing one. Attributing zero of them to
# a suite is what makes an unexplained red look like a green.
if [ "$rc" != 0 ] && [ "$header_count" -eq 0 ]; then
  echo "[test-suite] FAIL - dune exited ${rc} and printed no failure header"
  echo
  tail -60 "$log"
  exit 2
fi

status=0
# Every header has to resolve to a suite, or the delta below cannot read the
# run: a compile error in a test module, a rule with no alias name, a stanza
# shape this reader does not know. The old guard fired only when nothing at
# all was attributed, which the nine known failures made impossible.
if [ "$header_count" -ne "$attributed_count" ]; then
  status=2
  echo "[test-suite] FAIL - ${header_count} failure headers, ${attributed_count} attributed to a suite"
  echo
  awk -F'\t' '$1 == "-" { print $2 }' "$tmp/attributed.tsv" | while IFS= read -r header; do
    echo "--- unattributed: $header ---"
    print_block_from_header "$header" "$log" | head -40
  done
  echo
fi

new="$(comm -23 "$tmp/failed.txt" "$tmp/known.txt")"
if [ -n "$new" ]; then
  [ "$status" = 0 ] && status=1
  echo "[test-suite] FAIL - suites broke that $known_file does not list"
  echo
  printf '%s\n' "$new" | sed 's/^/  - /'
  echo
  echo "Fix the suite. Adding it to $known_file records the break as normal,"
  echo "which is how the last six spent a month unnoticed."
  echo
  for name in $new; do
    echo "--- $name ---"
    # Print the exact Dune failure block, including Alcotest's case name and
    # assertion after the blank line that follows its run ID. Match the suite
    # name from the stanza line instead of a substring in another executable.
    print_failure_block "$name" "$log"
  done
fi

fixed="$(comm -13 "$tmp/failed.txt" "$tmp/known.txt")"
if [ -n "$fixed" ]; then
  [ "$status" = 0 ] && status=1
  echo "[test-suite] FAIL - $known_file lists suites that now pass"
  echo
  printf '%s\n' "$fixed" | sed 's/^/  - /'
  echo
  echo "Take these lines out of $known_file. Leaving them is slack: the next"
  echo "suite to break can take the empty slot and still read as expected."
fi

if [ "$status" = 0 ]; then
  echo "[test-suite] OK - ${failed_count} suites failed, all ${known_count} known"
  echo "[test-suite] dune reported ${header_count} failure headers, all attributed"
fi
exit "$status"
