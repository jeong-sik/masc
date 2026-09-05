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

# The header dune prints before a failure or warning it can locate:
#   File "test/dune", line 1089, characters 2-16:
#   File "test/dune", lines 2961-2970, characters 0-202:
#   File "test/test_x.ml", line 12, characters 4-10:
# The quoted source lines after it each start with the line number and a bar.
header_re='^File "[^"]+", lines? [0-9]+(-[0-9]+)?(, characters [0-9]+-[0-9]+)?:$'

# One line per header in the log, tab-separated: the suite key, the kind, the
# header itself. The key is "-" when no suite could be read; the kind is
# "warning" when the line after the quote starts with Warning, "failure"
# otherwise.
#
# A suite key is <dir>/<name>: the directory whose dune file declares the
# suite, then the stanza name. A bare name is ambiguous now that the root
# alias runs both test/ and packages/agent_core/test, which declare
# test_session, test_trajectory, test_schema_surface_index and others under
# one name; test/dune and test/multimodal/dune already shared test_workspace.
# The .inc files under test/stanzas/ are (include)d by test/dune, so a suite
# declared there is keyed under test/, where its executable is built.
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
# lines and names its suite in an alias, read across the whole quote. The
# last resort is the first whole atom in the quote that starts with test_;
# agent_core_test_deps is one atom and yields nothing. A header for a .ml
# file is a compile error and names no suite. Headers used to be read only
# from test/dune and test/stanzas/*.inc, so a failure in any of the 18
# test/<dir>/dune files or in packages/ was dropped whenever another suite
# also failed; now every header is listed and the caller refuses a run in
# which a failure header names no suite.
attribute_failures() {
  awk -v header_re="$header_re" '
    function resolve(   atom, s, rest, tok) {
      if (!dune_file) return ""
      if (first_src != "" && from >= 0) {
        atom = substr(first_src, from + 1, to - from)
        if (atom ~ /^[A-Za-z0-9_][A-Za-z0-9_.-]*$/) return atom
      }
      if (match(quote, /\(alias +runtest-[A-Za-z0-9_-]+/)) {
        s = substr(quote, RSTART, RLENGTH); sub(/.*runtest-/, "", s); return s
      }
      rest = quote
      while (match(rest, /[A-Za-z0-9_][A-Za-z0-9_-]*/)) {
        tok = substr(rest, RSTART, RLENGTH)
        if (tok ~ /^test_/) return tok
        rest = substr(rest, RSTART + RLENGTH)
      }
      return ""
    }
    function flush(   name) {
      if (header != "") {
        name = resolve()
        printf "%s\t%s\t%s\n", (name == "" ? "-" : dir "/" name), kind, header
      }
      header = ""; quote = ""; first_src = ""
    }
    $0 ~ header_re {
      flush()
      header = $0; kind = "failure"
      file = $0; sub(/^File "/, "", file); sub(/".*/, "", file)
      dune_file = (file ~ /(^|\/)dune$/ || file ~ /\.inc$/)
      dir = file
      if (dir ~ /\//) sub(/\/[^\/]*$/, "", dir); else dir = "."
      if (file ~ /\.inc$/) sub(/\/stanzas$/, "", dir)
      from = -1; to = -1
      if (dune_file && match($0, /line [0-9]+, characters [0-9]+-[0-9]+:$/)) {
        range = substr($0, RSTART, RLENGTH)
        sub(/.*characters /, "", range); sub(/:$/, "", range)
        split(range, cols, "-"); from = cols[1] + 0; to = cols[2] + 0
      }
      next
    }
    header == "" { next }
    $0 !~ /^ *[0-9]+ \|/ {
      if ($0 ~ /^Warning/) kind = "warning"
      flush()
      next
    }
    {
      src = substr($0, index($0, "| ") + 2)
      if (quote == "") first_src = src
      quote = quote src "\n"
    }
    END { flush() }
  ' "$1"
}

extract_failed_names() {
  attribute_failures "$1" | awk -F'\t' '$2 == "failure" && $1 != "-" { print $1 }'
}

# "<failure headers> <attributed>" for an attribution listing; warnings are
# not failures and count in neither.
count_attribution() {
  awk -F'\t' '
    $2 == "failure" { headers++ }
    $2 == "failure" && $1 != "-" { named++ }
    END { print headers + 0, named + 0 }' "$1"
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
  local key="$1"
  local source_log="$2"
  local header
  header="$(attribute_failures "$source_log" \
    | awk -F'\t' -v k="$key" '$2 == "failure" && $1 == k { print $3; exit }')"
  [ -n "$header" ] && print_block_from_header "$header" "$source_log"
}

# The process columns this script reads: pid, parent, group, elapsed, argv.
process_table() {
  ps -axo pid=,ppid=,pgid=,etime=,args=
}

# The rows of process $1 and its descendants, from process_table lines on
# stdin, followed through parent links. Not through the process group: dune
# 3.24.1 (masc.opam.locked) starts every action in a group of its own --
# src/dune_engine/process.ml, run_internal, setpgid = Some
# Spawn.Pgid.new_process_group -- so a suite's group holds only the suite,
# and dune's group holds no suite at all.
process_tree_of() {
  awk -v root="$1" '
    { pid[NR] = $1; parent[$1] = $2; row[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        p = pid[i]
        for (depth = 0; depth < 64 && p != "" && p != root; depth++) p = parent[p]
        if (p == root) print row[i]
      }
    }'
}

# "<name> <elapsed>" for each process_table row on stdin that is a built
# executable or a python suite file. Dune runs a suite as ./test_x.exe inside
# its sandbox, so argv[0] names it; the (rule) suites driven by python show
# their test file; a server binary a suite spawned is listed under its own
# name.
name_suite_processes() {
  awk '
    { name = "" }
    $5 ~ /\.exe$/ { name = $5; sub(/.*\//, "", name); sub(/\.exe$/, "", name) }
    name == "" && match($0, /test_[a-z0-9_]+\.py/) { name = substr($0, RSTART, RLENGTH - 3) }
    name != "" { print name " " $4 }'
}

# TERM every pid in the rows of file $1, give them $2 seconds, then KILL what
# is still there. The rows were taken before the first signal, so a child
# reparented when its parent dies is still on the list.
terminate_rows() {
  local pids
  local grace="$2"
  pids="$(awk '{ print $1 }' "$1" | tr '\n' ' ')"
  [ -n "${pids// /}" ] || return 0
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null
  # shellcheck disable=SC2086
  while [ "$grace" -gt 0 ] && kill -0 $pids 2>/dev/null; do
    sleep 1
    grace=$((grace - 1))
  done
  # shellcheck disable=SC2086
  kill -KILL $pids 2>/dev/null
}

# What a suite still running at the deadline was doing. Alcotest 1.9.1
# (alcotest-engine/log_trap.ml, core.ml perform_test) opens
# _build/_tests/<run id>/<group>.<index>.output under the suite's working
# directory when a case starts and redirects the case's output there, so
# under a running suite the newest file names the case in progress, by its
# group and its index in that group, and holds whatever it printed; the
# files before it hold the assertions of the cases that finished. The run
# id directory has two sibling symlinks, the suite name and `latest`. Dune
# runs each suite in a sandbox under _build/.sandbox and removes the sandbox
# when the action ends, so at the deadline only the suites still running
# have files there, and the listing has to be taken before the tree is
# killed. The nightly of 2026-09-05 named its two hung suites and nothing
# else (#33200); this names the case.
alcotest_outputs_at_deadline=6
alcotest_output_tail_lines=40

# "<mtime epoch> <path>" for the newest .output files under sandbox root
# $1, oldest first, at most alcotest_outputs_at_deadline of them. GNU find:
# the deadline path runs on the Linux runner. Symlinks are not followed, so
# each file is listed once, under its run id.
newest_alcotest_outputs() {
  [ -d "$1" ] || return 0
  find "$1" -path '*/_build/_tests/*.output' -type f -printf '%T@ %p\n' 2>/dev/null \
    | sort -n | tail -n "$alcotest_outputs_at_deadline"
}

# The suite name of alcotest run directory $1: the sibling symlink to it
# that is not `latest`, or the run id when there is none.
alcotest_suite_of() {
  local run_dir="$1"
  local link
  for link in "$(dirname "$run_dir")"/*; do
    [ -L "$link" ] || continue
    [ "$(basename "$link")" != latest ] || continue
    if [ "$(basename "$(readlink "$link")")" = "$(basename "$run_dir")" ]; then
      basename "$link"
      return 0
    fi
  done
  basename "$run_dir"
}

# For each newest_alcotest_outputs line on stdin: the suite and the file
# name alcotest chose, how long before epoch $1 the file was last written,
# and its last alcotest_output_tail_lines lines.
print_alcotest_outputs() {
  local now="$1"
  local mtime path suite file
  while read -r mtime path; do
    suite="$(alcotest_suite_of "$(dirname "$path")")"
    file="$(basename "$path")"
    echo "[test-suite] alcotest output in flight: ${suite}/${file}," \
         "last written $(( now - ${mtime%.*} ))s before the deadline"
    echo "[test-suite]   ${path}"
    tail -n "$alcotest_output_tail_lines" "$path" | sed 's/^/    /'
  done
}

self_test() {
  local exact_block
  local longer_block
  fixture_log="$(mktemp "${TMPDIR:-/tmp}/masc-test-suite-self-test.XXXXXX")"
  fixture_rows="$(mktemp "${TMPDIR:-/tmp}/masc-test-suite-rows.XXXXXX")"
  trap 'terminate_rows "$fixture_rows" 1; rm -f "$fixture_log" "$fixture_rows"' EXIT

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

  exact_block="$(print_failure_block test/test_ci_failure_output "$fixture_log")"
  longer_block="$(print_failure_block test/test_ci_failure_output_extra "$fixture_log")"

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
1450 |  (deps a b)
1451 |  (alias runtest-dashboard-http-behavior-contracts))
Command exited with code 1.
File "test/stanzas/test_keeper_toml.inc", line 2, characters 1-40:
2 |  (name test_keeper_toml)

  [FAIL]        toml          3   a named suite still reads.
EOF

  names="$(extract_failed_names "$rule_log" | sort -u | tr '\n' ' ')"
  [ "$names" = "test/dashboard-http-behavior-contracts test/test_keeper_toml test/test_tui_keyboard_input " ] \
    || { echo "[test-suite] self-test FAIL - rule-declared suites are unnamed: $names" >&2
         rm -f "$rule_log"; exit 1; }

  printf '%s\n' "$(print_failure_block test/test_tui_keyboard_input "$rule_log")" \
    | grep -Fq 'AssertionError: a scenario the gate could not name' \
    || { echo "[test-suite] self-test FAIL - a rule's own output is missing" >&2
         rm -f "$rule_log"; exit 1; }

  if printf '%s\n' "$(print_failure_block test/test_tui_keyboard_input "$rule_log")" \
     | grep -Fq 'a named suite still reads'; then
    echo "[test-suite] self-test FAIL - a later suite leaked into the rule block" >&2
    rm -f "$rule_log"; exit 1
  fi

  rm -f "$rule_log"
  echo "[test-suite] self-test OK - a (rule ...) stanza names its suite"

  # Headers outside test/dune: a test/<dir>/dune file, packages/, a one-line
  # (names ...) list where the second name failed, a name without the test_
  # prefix, and one name declared in two directories. The character range,
  # not the first test_ word, picks the suite, and the directory keeps the
  # two test_session apart.
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
File "test/dune", line 500, characters 2-14:
500 |   test_session
  [FAIL]        session        0   the test/ one.
File "packages/agent_core/test/dune", line 90, characters 2-14:
90 |   test_session
  [FAIL]        session        0   the packages/ one.
EOF

  names="$(extract_failed_names "$subdir_log" | tr '\n' ' ')"
  [ "$names" = "test/keeper_event_queue/test_keeper_event_queue packages/agent_core/test/test_agent_race test/fusion_core/test_fusion_harness tools/tlc_test_gen/sample_outputs/nested_sample_runner test/test_session packages/agent_core/test/test_session " ] \
    || { echo "[test-suite] self-test FAIL - headers outside test/dune are misread: $names" >&2
         rm -f "$subdir_log"; exit 1; }

  printf '%s\n' "$(print_failure_block test/fusion_core/test_fusion_harness "$subdir_log")" \
    | grep -Fq 'the second name on the line' \
    || { echo "[test-suite] self-test FAIL - the block for a column-picked name is missing" >&2
         rm -f "$subdir_log"; exit 1; }

  printf '%s\n' "$(print_failure_block packages/agent_core/test/test_session "$subdir_log")" \
    | grep -Fq 'the packages/ one' \
    || { echo "[test-suite] self-test FAIL - the second test_session block is not its own" >&2
         rm -f "$subdir_log"; exit 1; }

  rm -f "$subdir_log"
  echo "[test-suite] self-test OK - a header outside test/dune names its suite"

  # A compile error prints a header for the .ml file and names no suite; a
  # library stanza that quotes agent_core_test_deps names no suite either,
  # since test_deps is not an atom of its own. The count has to show the gap,
  # or the run reads as its known failures only. A dune warning has the same
  # header and is neither a failure nor a gap.
  gap_log="$(mktemp "${TMPDIR:-/tmp}/masc-test-suite-gap.XXXXXX")"
  cat > "$gap_log" <<'EOF'
File "test/test_broken_module.ml", line 3, characters 8-21:
3 | let x = missing_value
Error: Unbound value missing_value
File "packages/agent_core/test/dune", lines 1-4, characters 0-90:
1 | (library
2 |  (name agent_core_test_deps)
3 |  (modules agent_core_test_deps)
4 |  (libraries missing_library))
Error: Library "missing_library" not found.
File "test/stanzas/test_keeper_toml.inc", line 2, characters 1-40:
2 |  (name test_keeper_toml)
  [FAIL]        toml          3   a named suite still reads.
File "test/dune", line 7, characters 1-24:
7 |  (deprecated_field true)
Warning: deprecated_field is deprecated.
EOF

  gap_tsv="$(mktemp "${TMPDIR:-/tmp}/masc-test-suite-gap-tsv.XXXXXX")"
  attribute_failures "$gap_log" > "$gap_tsv"
  counts="$(count_attribution "$gap_tsv")"
  [ "$counts" = "3 1" ] \
    || { echo "[test-suite] self-test FAIL - expected 3 failure headers 1 attributed, got: $counts" >&2
         rm -f "$gap_log" "$gap_tsv"; exit 1; }
  unattributed="$(awk -F'\t' '$2 == "failure" && $1 == "-" { print $3 }' "$gap_tsv" | tr '\n' ';')"
  [ "$unattributed" = 'File "test/test_broken_module.ml", line 3, characters 8-21:;File "packages/agent_core/test/dune", lines 1-4, characters 0-90:;' ] \
    || { echo "[test-suite] self-test FAIL - the unattributed headers are wrong: $unattributed" >&2
         rm -f "$gap_log" "$gap_tsv"; exit 1; }
  warnings="$(awk -F'\t' '$2 == "warning" { print $3 }' "$gap_tsv")"
  [ "$warnings" = 'File "test/dune", line 7, characters 1-24:' ] \
    || { echo "[test-suite] self-test FAIL - the warning header is not read as a warning: $warnings" >&2
         rm -f "$gap_log" "$gap_tsv"; exit 1; }
  printf '%s\n' "$(print_block_from_header 'File "test/test_broken_module.ml", line 3, characters 8-21:' "$gap_log")" \
    | grep -Fq 'Error: Unbound value missing_value' \
    || { echo "[test-suite] self-test FAIL - the unattributed block lost its error line" >&2
         rm -f "$gap_log" "$gap_tsv"; exit 1; }

  rm -f "$gap_log" "$gap_tsv"
  echo "[test-suite] self-test OK - a header that names no suite is counted, a warning is not"

  # What the deadline snapshot reads from process rows: a dune-run suite, a
  # python rule and a server binary a suite spawned; not a shell.
  running="$(printf '%s\n' \
      '4242 4000 4242    01:15:02 ./test_keeper_owner.exe' \
      '4243 4000 4243       05:00 python3 /home/r/w/test/test_tui_keyboard_input.py --pty' \
      '4244 4242 4244       00:02 bash -c sleep 3' \
      '4245 4242 4245    00:00:40 /home/r/w/_build/default/bin/masc_server.exe --port 1' \
    | name_suite_processes | tr '\n' ';')"
  [ "$running" = "test_keeper_owner 01:15:02;test_tui_keyboard_input 05:00;masc_server 00:00:40;" ] \
    || { echo "[test-suite] self-test FAIL - the deadline snapshot misnames processes: $running" >&2
         exit 1; }
  echo "[test-suite] self-test OK - the deadline snapshot names suite processes"

  # A live tree, with the suite in a process group of its own the way dune
  # 3.24 starts every action: the parent walk finds it, its group would not,
  # and termination reaches it.
  fixture_py="$(mktemp "${TMPDIR:-/tmp}/masc-test-suite-setpgid.XXXXXX")"
  cat > "$fixture_py" <<'EOF'
import os
os.setpgrp()
os.execvp("sleep", ["./test_setpgid_suite.exe", "60"])
EOF
  # The middle shell traps TERM so it exits normally once the suite is
  # gone, and its stderr is dropped: the shell reports the suite's death by
  # signal there, which is the expected outcome, not a finding.
  bash -c "trap : TERM; python3 '$fixture_py'; :" 2>/dev/null &
  fixture_root=$!
  sleep 2
  process_table | process_tree_of "$fixture_root" > "$fixture_rows"
  rm -f "$fixture_py"
  running="$(name_suite_processes < "$fixture_rows")"
  case "$running" in
    "test_setpgid_suite "*) ;;
    *) echo "[test-suite] self-test FAIL - the parent walk did not reach the suite: [$running]" >&2
       exit 1 ;;
  esac
  root_pgid="$(awk -v r="$fixture_root" '$1 == r { print $3 }' "$fixture_rows")"
  suite_pgid="$(awk '$5 ~ /test_setpgid_suite/ { print $3 }' "$fixture_rows")"
  suite_pid="$(awk '$5 ~ /test_setpgid_suite/ { print $1 }' "$fixture_rows")"
  [ -n "$suite_pgid" ] && [ "$suite_pgid" != "$root_pgid" ] \
    || { echo "[test-suite] self-test FAIL - the fixture suite is not in a group of its own (root $root_pgid, suite $suite_pgid)" >&2
         exit 1; }
  terminate_rows "$fixture_rows" 5
  wait "$fixture_root" 2>/dev/null
  if kill -0 "$suite_pid" 2>/dev/null; then
    echo "[test-suite] self-test FAIL - the suite in its own group survived termination" >&2
    exit 1
  fi
  : > "$fixture_rows"
  echo "[test-suite] self-test OK - a suite in its own process group is found and terminated"

  # The deadline listing of alcotest case output, on the layout alcotest
  # 1.9.1 writes: two sandboxes, each with a run id directory and the suite
  # name and `latest` symlinks beside it. The newest file under each suite
  # comes last, a file longer than the tail is cut to its last lines, one
  # file more than the listing holds is dropped as the oldest, the symlinks
  # are not followed, and the suite is named from its symlink. BSD find has
  # no -printf; the listing runs on the Linux runner, so the check is
  # skipped where it is missing.
  if ! find . -maxdepth 0 -printf '' 2>/dev/null; then
    echo "[test-suite] self-test SKIP - find has no -printf; the deadline listing runs on the Linux runner"
    return 0
  fi
  fixture_sandbox="$(mktemp -d "${TMPDIR:-/tmp}/masc-test-suite-sandbox.XXXXXX")"
  heartbeat_tests="$fixture_sandbox/aa11/default/test/_build/_tests"
  hitl_tests="$fixture_sandbox/bb22/default/test/_build/_tests"
  heartbeat_dir="$heartbeat_tests/6A8F1C2B"
  hitl_dir="$hitl_tests/0D3E9B47"
  mkdir -p "$heartbeat_dir" "$hitl_dir"
  ln -s "$heartbeat_dir" "$heartbeat_tests/Heartbeat_integration"
  ln -s "$heartbeat_dir" "$heartbeat_tests/latest"
  ln -s "$hitl_dir" "$hitl_tests/Hitl_summary_worker"
  ln -s "$hitl_dir" "$hitl_tests/latest"
  seq 1 50 | sed 's/^/heartbeat line /' > "$heartbeat_dir/lifecycle.004.output"
  printf 'started the case that hangs\n' > "$heartbeat_dir/lifecycle.005.output"
  printf 'ASSERT worker case 011 failed first\n' > "$hitl_dir/worker.011.output"
  printf 'worker case 012 in flight\n' > "$hitl_dir/worker.012.output"
  for stale in 1 2 3; do
    printf 'stale %s\n' "$stale" > "$hitl_dir/worker.00${stale}.output"
    touch -t 202601010${stale}00 "$hitl_dir/worker.00${stale}.output"
  done
  touch -t 202609050100 "$heartbeat_dir/lifecycle.004.output"
  touch -t 202609050200 "$hitl_dir/worker.011.output"
  touch -t 202609050300 "$heartbeat_dir/lifecycle.005.output"
  touch -t 202609050400 "$hitl_dir/worker.012.output"
  listing="$(newest_alcotest_outputs "$fixture_sandbox" | awk '{ print $2 }' | sed "s#^$fixture_sandbox/##" | tr '\n' ';')"
  [ "$listing" = "bb22/default/test/_build/_tests/0D3E9B47/worker.002.output;bb22/default/test/_build/_tests/0D3E9B47/worker.003.output;aa11/default/test/_build/_tests/6A8F1C2B/lifecycle.004.output;bb22/default/test/_build/_tests/0D3E9B47/worker.011.output;aa11/default/test/_build/_tests/6A8F1C2B/lifecycle.005.output;bb22/default/test/_build/_tests/0D3E9B47/worker.012.output;" ] \
    || { echo "[test-suite] self-test FAIL - the newest alcotest outputs are misordered or miscounted: $listing" >&2
         rm -rf "$fixture_sandbox"; exit 1; }
  rendered="$(newest_alcotest_outputs "$fixture_sandbox" | print_alcotest_outputs "$(date +%s)")"
  printf '%s\n' "$rendered" | grep -Fq 'alcotest output in flight: Heartbeat_integration/lifecycle.005.output' \
    || { echo "[test-suite] self-test FAIL - the case in flight is not named by its suite symlink" >&2
         rm -rf "$fixture_sandbox"; exit 1; }
  printf '%s\n' "$rendered" | grep -Fq 'alcotest output in flight: Hitl_summary_worker/worker.012.output' \
    || { echo "[test-suite] self-test FAIL - the second suite is not named by its symlink" >&2
         rm -rf "$fixture_sandbox"; exit 1; }
  printf '%s\n' "$rendered" | grep -Fq '    ASSERT worker case 011 failed first' \
    || { echo "[test-suite] self-test FAIL - the finished case's assertion is missing" >&2
         rm -rf "$fixture_sandbox"; exit 1; }
  printf '%s\n' "$rendered" | grep -Fq '    heartbeat line 11' \
    || { echo "[test-suite] self-test FAIL - the tail of a long output is missing" >&2
         rm -rf "$fixture_sandbox"; exit 1; }
  if printf '%s\n' "$rendered" | grep -Fq 'heartbeat line 10'; then
    echo "[test-suite] self-test FAIL - a long output is not cut to its tail" >&2
    rm -rf "$fixture_sandbox"; exit 1
  fi
  rm -rf "$fixture_sandbox"
  echo "[test-suite] self-test OK - the deadline listing names the alcotest case in flight"
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
tree_at_deadline="$tmp/test-suite-tree-at-deadline.txt"
running_at_deadline="$tmp/test-suite-running-at-deadline.txt"
alcotest_outputs_at_deadline_file="$tmp/test-suite-alcotest-outputs-at-deadline.txt"
sandbox_root="_build/.sandbox"

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
# process tree under dune is recorded, the executables in it are named, the
# alcotest case output still in the running suites' sandboxes is rendered
# while the sandboxes exist, and the whole tree gets TERM, then KILL after a
# grace period; rc is 124 as before.
run_suite_under_deadline() {
  opam exec -- dune build --root . "$alias_target" > "$log" 2>&1 &
  local dune_pid=$!
  local exited
  local now
  rc=""
  : > "$running_at_deadline"
  : > "$alcotest_outputs_at_deadline_file"
  while kill -0 "$dune_pid" 2>/dev/null; do
    now=$(date +%s)
    if [ $(( now - started )) -ge "$deadline" ]; then
      process_table | process_tree_of "$dune_pid" > "$tree_at_deadline"
      name_suite_processes < "$tree_at_deadline" > "$running_at_deadline"
      newest_alcotest_outputs "$sandbox_root" \
        | print_alcotest_outputs "$now" > "$alcotest_outputs_at_deadline_file"
      terminate_rows "$tree_at_deadline" 30
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
    echo "[test-suite] running at deadline: no executable under dune;" \
         "dune was still building or linking, or the hang is not a suite process"
  fi
  echo "[test-suite] process tree under dune at deadline:"
  sed 's/^/  /' "$tree_at_deadline"
  if [ -s "$alcotest_outputs_at_deadline_file" ]; then
    echo "[test-suite] alcotest case output in the running suites' sandboxes at deadline, newest last:"
    cat "$alcotest_outputs_at_deadline_file"
  else
    echo "[test-suite] alcotest case output at deadline: no .output file under $sandbox_root;" \
         "no suite had started a case, or the suites run outside a sandbox"
  fi
  echo
  tail -60 "$log"
  exit 2
fi

attribute_failures "$log" > "$tmp/attributed.tsv"
awk -F'\t' '$2 == "failure" && $1 != "-" { print $1 }' "$tmp/attributed.tsv" | sort -u \
  > "$tmp/failed.txt"

sed 's/#.*//' "$known_file" | tr -d '[:blank:]' | grep -v '^$' | sort -u \
  > "$tmp/known.txt"

failed_count=$(wc -l < "$tmp/failed.txt" | tr -d ' ')
known_count=$(wc -l < "$tmp/known.txt" | tr -d ' ')
read -r header_count attributed_count < <(count_attribution "$tmp/attributed.tsv")

awk -F'\t' '$2 == "warning" { print "[test-suite] dune warning, not a failure: " $3 }' \
  "$tmp/attributed.tsv"

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
# Every failure header has to resolve to a suite, or the delta below cannot
# read the run: a compile error in a test module, a rule with no alias name,
# a stanza shape this reader does not know. The old guard fired only when
# nothing at all was attributed, which the nine known failures made
# impossible.
if [ "$header_count" -ne "$attributed_count" ]; then
  status=2
  echo "[test-suite] FAIL - ${header_count} failure headers, ${attributed_count} attributed to a suite"
  echo
  awk -F'\t' '$2 == "failure" && $1 == "-" { print $3 }' "$tmp/attributed.tsv" \
    | while IFS= read -r header; do
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
  for key in $new; do
    echo "--- $key ---"
    # Print the exact Dune failure block, including Alcotest's case name and
    # assertion after the blank line that follows its run ID. Match the suite
    # key from the stanza header instead of a substring in another executable.
    print_failure_block "$key" "$log"
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
