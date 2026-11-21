#!/usr/bin/env bash
# Run only explicitly named behavior suites, shared by local verification and CI.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"
: "${TARGET_SUITES:=}"
: "${TARGET_SUITE_TIMEOUT_SEC:=600}"
: "${TARGET_SUITE_KILL_GRACE_SEC:=30}"
if [ -z "${CI_TEST_LOG_FILE:-}" ]; then
  CI_TEST_LOG_FILE=$(mktemp "${TMPDIR:-/tmp}/masc-targeted-tests.XXXXXX")
fi
# Deployment-local roots must not override a suite's declared fixture roots.
unset MASC_CONFIG_DIR MASC_BASE_PATH MASC_BASE_PATH_INPUT MASC_BASE_PATH_RESOLUTION_SOURCE
log() { printf '%s\n' "$*" | tee -a "${CI_TEST_LOG_FILE}"; }
DUNE_SOURCEROOT="${repo_root}"
export DUNE_SOURCEROOT
if [ -n "${TARGET_EIO_BACKEND:-}" ]; then
  export EIO_BACKEND="${TARGET_EIO_BACKEND:-}"
fi
suite_tool="${repo_root}/scripts/ci/targeted_suites.py"
# Shard support: SHARD_COUNT + SHARD_INDEX split the full behavioural
# suite across workflow matrix jobs. The nightly measured one job growing
# _build/<hash>/default/test by ~24G to 97% disk (run 43858983604), and
# between-suite cleanup cannot help inside a single sequential job, so
# the split itself is the fix. With both vars set and no explicit
# TARGET_SUITES, suites are enumerated via scripts/ci/targeted_suites.py from
# Dune's declared `(test)`/`(tests)` stanzas (preserving subdirectory paths and
# evaluating `(enabled_if ...)` predicates) plus the `runtest-<name>` rules
# referenced by `test/dune`'s `(alias (name runtest))` bundles — never raw
# helper `.ml`/`.py` files or bare directory names — then filtered by a stable
# checksum so every runner assigns every suite identically. Explicit
# TARGET_SUITES always wins, so the pull-request gate and targeted dispatches
# are untouched.
if [ -n "${SHARD_COUNT:-}" ] && [ -n "${SHARD_INDEX:-}" ] && [ -z "${TARGET_SUITES}" ]; then
  case "${SHARD_COUNT}" in *[!0-9]*|"") log "[targeted] FAIL - shard: SHARD_COUNT is not a number"; exit 2;; esac
  case "${SHARD_INDEX}" in *[!0-9]*|"") log "[targeted] FAIL - shard: SHARD_INDEX is not a number"; exit 2;; esac
  if [ "${SHARD_COUNT}" -lt 1 ] || [ "${SHARD_INDEX}" -ge "${SHARD_COUNT}" ]; then
    log "[targeted] FAIL - shard: need SHARD_COUNT >= 1 and SHARD_INDEX in [0,SHARD_COUNT)"
    exit 2
  fi
  shard_enum_output="$(python3 "${suite_tool}" enumerate --repo-root "${repo_root}")"
  shard_list=""
  shard_n=0
  while IFS= read -r name; do
    [ -n "${name}" ] || continue
    if [ "$(( $(printf '%s' "${name}" | cksum | cut -d' ' -f1) % SHARD_COUNT ))" -eq "${SHARD_INDEX}" ]; then
      shard_list="${shard_list:+${shard_list},}${name}"
      shard_n=$((shard_n + 1))
    fi
  done <<< "${shard_enum_output}"
  if [ "${shard_n}" -eq 0 ]; then
    log "[targeted] FAIL - shard ${SHARD_INDEX}/${SHARD_COUNT}: enumeration matched nothing"
    exit 2
  fi
  TARGET_SUITES="${shard_list}"
  log "[targeted] shard ${SHARD_INDEX}/${SHARD_COUNT}: ${shard_n} suites"
fi

# Every suite runs as a Dune alias. aliases[i] is what `dune build` runs;
# alias_dirs[i] and alias_names[i] name the dune file and the suite the
# prebuild reader looks up for it.
aliases=()
alias_dirs=()
alias_names=()
alias_exes=()
alias_deps=()
unresolved=()
undeclared_suites=()
undeclared_paths=()
candidate_ocaml_suites=()
candidate_ocaml_paths=()
prebuild_reader="${repo_root}/scripts/ci/alias_prebuild_deps.py"
runtest_aliases="$(python3 "${suite_tool}" list-runtest-aliases --repo-root "${repo_root}")"
IFS=',' read -r -a requested <<< "${TARGET_SUITES}"
for suite in ${requested[@]+"${requested[@]}"}; do
  suite="${suite// /}"
  [ -n "${suite}" ] || continue
  # A suite that is a script under a dune alias rather than an
  # executable. Three spellings reach the same place: test/<suite>.py
  # for a script named after its file, the same written as a path
  # from the root, and any name a test/ dune file declares as
  # (alias runtest-<suite>) — the PTY suite's per-family lanes are
  # named that way and have no file of their own. Dune runs the
  # script as the alias's action, so building the alias is the run.
  #
  # The path spelling is accepted because the .ml branch below takes
  # it and an OCaml suite in its own directory needs it, so the two
  # halves of one input read differently otherwise. Measured
  # 2026-09-14: three dispatches in forty minutes named a Python
  # suite as test/<name> and each burned a full build to say the
  # name resolved to nothing. The alias itself is the stem, never
  # the path.
  #
  # A name with no directory in it is the only one matched against
  # the declared aliases: those are bare names, and taking the last
  # segment of a path to match one would let an OCaml suite under
  # packages/ be answered by a same-named alias under test/.
  if [ -f "test/${suite}.py" ] || [ -f "${suite}.py" ]; then
    aliases+=("@runtest-${suite##*/}")
    alias_dirs+=("test")
    alias_names+=("${suite##*/}")
  elif [ "${suite}" = "${suite##*/}" ] \
    && [[ $'\n'"${runtest_aliases}"$'\n' == *$'\n'"${suite}"$'\n'* ]]; then
    aliases+=("@runtest-${suite}")
    alias_dirs+=("test")
    alias_names+=("${suite}")
  else
    # The name used to be a path fragment under test/, so a suite
    # outside it was unreachable: every one of the 43 under
    # packages/agent_core/test and tools/ could only run in the
    # nightly root @runtest, and a fix to one waited a night to be
    # seen. Resolve the name instead -- under test/ first, so
    # test_string_util and toml_line_editor/test_toml_line_editor
    # keep meaning what they meant, then from the repo root, which
    # is how packages/agent_core/test/test_provider is written.
    if [ -f "test/${suite}.ml" ]; then
      suite_path="test/${suite}"
    elif [ -f "${suite}.ml" ]; then
      suite_path="${suite}"
    else
      unresolved+=("${suite}")
      continue
    fi
    candidate_ocaml_suites+=("${suite}")
    candidate_ocaml_paths+=("${suite_path}")
  fi
done
# Batch-verify every OCaml .ml candidate against its directory's Dune
# `(test)`/`(tests)` stanzas so helper modules (which have `.ml` files on disk
# but no executable stanza) are reported cleanly as unresolved instead of
# failing the whole batch's `dune build` with "Don't know how to build".
if [ "${#candidate_ocaml_paths[@]}" -gt 0 ]; then
  verified_output="$(printf '%s\n' "${candidate_ocaml_paths[@]}" | python3 "${suite_tool}" verify-ocaml-suites --repo-root "${repo_root}")"
  idx=0
  while IFS=$'\t' read -r checked_path checked_status; do
    [ -n "${checked_path}" ] || continue
    if [ "${idx}" -ge "${#candidate_ocaml_paths[@]}" ] \
      || [ "${checked_path}" != "${candidate_ocaml_paths[$idx]}" ]; then
      log "[targeted] FAIL - verify-ocaml-suites alignment mismatch at index ${idx}: got '${checked_path}'"
      exit 2
    fi
    orig_suite="${candidate_ocaml_suites[$idx]}"
    suite_path="${candidate_ocaml_paths[$idx]}"
    idx=$((idx + 1))
    case "${checked_status}" in
      OK)
        # Dune runs the suite through the per-test alias it generates for every
        # named test (Dune 3.20+, below this repository's 3.22 minimum). The
        # stanza's (setenv ...), the directory's (env ...), its deps and the
        # working directory are then the ones the root @runtest uses. Running
        # the executable from the shell instead meant re-reading each of those
        # here, and every one that was missed produced a verdict the nightly
        # lane did not agree with. The double @ keeps the alias to this
        # directory.
        aliases+=("@@$(dirname "${suite_path}")/runtest-$(basename "${suite_path}")")
        alias_dirs+=("$(dirname "${suite_path}")")
        alias_names+=("$(basename "${suite_path}")")
        alias_exes+=("${suite_path}.exe")
        ;;
      UNDECLARED)
        undeclared_suites+=("${orig_suite}")
        undeclared_paths+=("${suite_path}")
        ;;
      *)
        log "[targeted] FAIL - verify-ocaml-suites returned unexpected status '${checked_status}' for '${checked_path}'"
        exit 2
        ;;
    esac
  done <<< "${verified_output}"
  if [ "${idx}" -ne "${#candidate_ocaml_paths[@]}" ]; then
    log "[targeted] FAIL - verify-ocaml-suites returned ${idx}/${#candidate_ocaml_paths[@]} entries"
    exit 2
  fi
fi
# A name that resolves to nothing used to end the dispatch right
# here, before a single suite was built, and it named only the first
# one it reached: a ten-suite batch with one misspelling returned no
# verdict for the other nine and did not say whether a second name
# was wrong too, so the next attempt could lose the batch again.
# Name every one of them, keep the run non-zero so nobody reads it
# as ten green suites, and let the ones that did resolve report.
resolution_status=0
if [ "${#unresolved[@]}" -ne 0 ]; then
  for suite in ${unresolved[@]+"${unresolved[@]}"}; do
    log "[targeted] FAIL - ${suite} names no suite: no test/${suite}.ml, ${suite}.ml, test/${suite}.py or ${suite}.py, and no (alias runtest-${suite##*/})"
  done
  resolution_status=1
fi
if [ "${#undeclared_suites[@]}" -ne 0 ]; then
  for i in "${!undeclared_suites[@]}"; do
    suite="${undeclared_suites[$i]}"
    suite_path="${undeclared_paths[$i]}"
    log "[targeted] FAIL - ${suite} has ${suite_path}.ml but no (test)/(tests) stanza declares $(basename "${suite_path}") in $(dirname "${suite_path}")/dune"
  done
  resolution_status=1
fi
# dune build with no target builds everything; a suite input of
# separators only must not turn into the full build.
if [ "${#aliases[@]}" -eq 0 ]; then
  log "[targeted] FAIL - the suite input names no suite: '${TARGET_SUITES}'"
  exit 2
fi
if command -v timeout >/dev/null 2>&1; then
  timeout_command=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  timeout_command=gtimeout
else
  log "[targeted] FAIL - GNU timeout is required (timeout or gtimeout)"
  exit 2
fi
log "[targeted] EIO_BACKEND=${EIO_BACKEND:-<unset>} timeout=${TARGET_SUITE_TIMEOUT_SEC}s per suite"
status="${resolution_status}"
# Compile selected OCaml executables before starting their alias budgets.
if [ "${#alias_exes[@]}" -gt 0 ]; then
  log "[targeted] dune build ${alias_exes[*]} (prepare alias executables)"
  opam exec -- dune build --root . -j "${DUNE_JOBS:-2}" "${alias_exes[@]}" \
    2>&1 | tee -a "${CI_TEST_LOG_FILE}"
fi
# The loop below runs each suite by building its alias, and building the
# alias compiles whatever its action needs inside the suite budget: a sibling
# binary such as ../bin/main_eio.exe, or a Python rule's Cargo and OCaml
# binaries. Measured: run 41730441832 spent 601s of a 600s budget compiling
# and printed no "Ran N tests" line at all. Build those here, outside the
# budget. The alias itself is not built: building it is running the suite.
for i in "${!aliases[@]}"; do
  alias_name="${alias_names[$i]}"
  # The reader failing is not this dispatch's failure: the alias is still
  # built under its own budget below, which is the behaviour before this
  # preparation existed. Say so instead of falling back silently -- a run
  # that quietly lost the preparation looks exactly like the 601s TIMEOUT it
  # was meant to prevent, and nobody re-reads a log that never complained.
  # Only the reader's stdout names build targets. What it writes to stderr
  # is kept apart and logged, so a warning from a reader that exits 0 is not
  # handed to dune as a target.
  alias_dep_stderr=$(mktemp "${TMPDIR:-/tmp}/masc-targeted-alias-deps.XXXXXX")
  if alias_dep_lines=$(python3 "${prebuild_reader}" "${alias_dirs[$i]}" "${alias_name}" 2>"${alias_dep_stderr}"); then
    if [ -s "${alias_dep_stderr}" ]; then
      log "[targeted] ${alias_name}: the deps reader wrote to stderr: $(cat "${alias_dep_stderr}")"
    fi
  else
    log "[targeted] ${alias_name}: could not read the alias deps; building the alias under its own budget instead: $(cat "${alias_dep_stderr}")"
    alias_dep_lines=""
  fi
  rm -f "${alias_dep_stderr}"
  while IFS= read -r alias_dep; do
    [ -n "${alias_dep}" ] || continue
    alias_deps+=("${alias_dep}")
  done <<< "${alias_dep_lines}"
done
# This build has no timeout of its own: it is the compile the suite budget
# must not pay for, and the job's own limit bounds it. When it fails, the run
# is marked failed and every alias still runs under its budget, where dune
# builds whatever is missing. Stopping here, as `set -e` would, left the other
# suites of the dispatch without a verdict.
if [ "${#alias_deps[@]}" -gt 0 ]; then
  log "[targeted] dune build ${alias_deps[*]} (prepare alias dependencies)"
  prepare_rc=0
  opam exec -- dune build --root . -j "${DUNE_JOBS:-2}" "${alias_deps[@]}" \
    2>&1 | tee -a "${CI_TEST_LOG_FILE}" || prepare_rc=$?
  if [ "${prepare_rc}" -ne 0 ]; then
    log "[targeted] FAIL - prepare alias dependencies: exit ${prepare_rc}; each alias still runs under its own budget"
    status=1
  fi
fi
# Stream fixture records directly to tee: buffered Dune output can
# truncate a successful suite mid-JSON. Keep actions serial so their
# evidence records cannot interleave.
for suite in "${aliases[@]}"; do
  log "[targeted] ${suite}: start $(date -u +%Y-%m-%dT%H:%M:%SZ) (dune alias)"
  started=$(date +%s)
  rc=0
  "${timeout_command}" -s TERM -k "${TARGET_SUITE_KILL_GRACE_SEC}" "${TARGET_SUITE_TIMEOUT_SEC}" \
    env ALCOTEST_VERBOSE=1 opam exec -- dune build --root . --force --no-buffer --verbose -j 1 "${suite}" \
    2>&1 | tee -a "${CI_TEST_LOG_FILE}" || rc=$?
  elapsed=$(( $(date +%s) - started ))
  # timeout(1) exits 124 when TERM ended the command and 137
  # when it took the KILL after the grace.
  case "${rc}" in
    0)   log "[targeted] ${suite}: OK in ${elapsed}s" ;;
    124|137)
         log "[targeted] ${suite}: TIMEOUT exit ${rc} after ${elapsed}s;" \
             "the hung case is the one after the last [OK] line above"
         status=1 ;;
    *)   log "[targeted] ${suite}: FAIL exit ${rc} in ${elapsed}s"
         status=1 ;;
  esac
done
exit "${status}"
