#!/usr/bin/env bash
# Run the complete Dune alias once. Dune owns the test verdict; this wrapper
# preserves the full log and captures running processes before a hang is stopped.
set -uo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root" || exit 2
alias_target="@runtest"

full_log_evidence() {
  local source_log="$1"
  if [ -n "${MASC_TEST_SUITE_LOG_ARTIFACT:-}" ]; then
    echo "[test-suite] the full dune log is uploaded as the ${MASC_TEST_SUITE_LOG_ARTIFACT} artifact."
  else
    echo "[test-suite] the full dune log is at ${source_log} on the runner;" \
         "the workflow does not upload that file."
  fi
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
alcotest_output_tail_lines=40

# "<mtime epoch> <path>" for, in every run id directory under sandbox root
# $1, the case in flight (the newest .output) and the case that finished
# last (the one before it, holding the assertions that preceded the hang);
# oldest first. Grouped by run directory, not taken as the newest few
# overall: the nightly of 2026-09-05 (run 33952796815) had two suites still
# running, the hitl suite had written six files after the heartbeat suite's
# last one, and a newest-six listing named hitl's cases and none of
# heartbeat's. GNU find: the deadline path runs on the Linux runner.
# Symlinks are not followed, so each file is listed once, under its run id.
# Tab-separated through awk because alcotest names its files after the
# group, which may hold spaces ("production exact flow.013.output").
newest_alcotest_outputs() {
  [ -d "$1" ] || return 0
  find "$1" -path '*/_build/_tests/*.output' -type f -printf '%T@\t%h\t%p\n' 2>/dev/null \
    | sort -n \
    | awk -F'\t' '{ before[$2] = newest[$2]; newest[$2] = $1 " " $3 }
                  END { for (dir in newest) {
                          if (before[dir] != "") print before[dir]
                          print newest[dir] } }' \
    | sort -n
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

# One budget for the whole suite. The job timeout above this is the last
# boundary; this one exists so a hang prints its diagnostics first.
deadline="${MASC_TEST_SUITE_DEADLINE:-5400}"
tmp="${RUNNER_TEMP:-/tmp}"
log="$tmp/test-suite.log"
tree_at_deadline="$tmp/test-suite-tree-at-deadline.txt"
running_at_deadline="$tmp/test-suite-running-at-deadline.txt"
alcotest_outputs_at_deadline_file="$tmp/test-suite-alcotest-outputs-at-deadline.txt"
sandbox_root="_build/.sandbox"

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
  full_log_evidence "$log"
  echo
  tail -60 "$log"
  exit 2
fi

if [ "$rc" != 0 ]; then
  echo "[test-suite] FAIL - dune exited ${rc}"
  full_log_evidence "$log"
  tail -120 "$log"
else
  echo "[test-suite] OK - dune completed the full @runtest alias"
fi
exit "$rc"
