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
suites=()
exes=()
aliases=()
unresolved=()
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
    aliases+=("${suite##*/}")
  elif [ "${suite}" = "${suite##*/}" ] \
    && grep -Eqr "^[[:space:]]*\(alias runtest-${suite}\)[[:space:]]*$" \
         test/dune test/stanzas 2>/dev/null; then
    aliases+=("${suite}")
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
    suites+=("${suite_path}")
    exes+=("${suite_path}.exe")
  fi
done
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
# dune build with no target builds everything; a suite input of
# separators only must not turn into the full build.
if [ "${#suites[@]}" -eq 0 ] && [ "${#aliases[@]}" -eq 0 ]; then
  log "[targeted] FAIL - the suite input names no executable: '${TARGET_SUITES}'"
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
# Stream fixture records directly to tee: buffered Dune output can
# truncate a successful suite mid-JSON. Keep actions serial so their
# evidence records cannot interleave.
for suite in ${aliases[@]+"${aliases[@]}"}; do
  log "[targeted] ${suite}: start $(date -u +%Y-%m-%dT%H:%M:%SZ) (dune alias)"
  started=$(date +%s)
  rc=0
  "${timeout_command}" -s TERM -k "${TARGET_SUITE_KILL_GRACE_SEC}" "${TARGET_SUITE_TIMEOUT_SEC}"               opam exec -- dune build --root . --force --no-buffer -j 1 "@runtest-${suite}" 2>&1 | tee -a "${CI_TEST_LOG_FILE}" || rc=$?
  elapsed=$(( $(date +%s) - started ))
  case "${rc}" in
    0)   log "[targeted] ${suite}: OK in ${elapsed}s" ;;
    124|137)
         log "[targeted] ${suite}: TIMEOUT exit ${rc} after ${elapsed}s"
         status=1 ;;
    *)   log "[targeted] ${suite}: FAIL exit ${rc} in ${elapsed}s"
         status=1 ;;
  esac
done
if [ "${#exes[@]}" -eq 0 ]; then
  exit "${status}"
fi
# A stanza's (setenv ...) belongs to dune's runtest action, so a run
# of the executable does not get it, and 22 of the 346 stanzas
# declare one. This file used to carry a case block that named
# exactly one of them, so a dispatch naming any of the other 21 ran
# that suite under the wrong environment and reported verdicts the
# nightly lane would not agree with -- silently, since a missing
# variable looks like a normal run. stanza_env.py reads the stanza.
# Captured, not piped: a failing script inside a process
# substitution leaves the loop's exit status at 0, and a suite that
# runs with no environment because the reader broke is the exact
# outcome this replaces.
stanza_env_reader="${repo_root}/scripts/ci/stanza_env.py"
# suites hold the resolved path; the reader takes the directory and
# the bare name, because a stanza names a suite without its path.
stanza_deps=()
for suite_path in "${suites[@]}"; do
  dep_lines=$(python3 "${stanza_env_reader}" \
    --dir "$(dirname "${suite_path}")" \
    --deps "$(basename "${suite_path}")")
  while IFS= read -r dep; do
    if [ -n "${dep}" ]; then stanza_deps+=("${dep}"); fi
  done <<< "${dep_lines}"
done
log "[targeted] dune build ${exes[*]} ${stanza_deps[*]+${stanza_deps[*]}}"
opam exec -- dune build --root . -j "${DUNE_JOBS:-2}" "${exes[@]}" \
  ${stanza_deps[@]+"${stanza_deps[@]}"} 2>&1 | tee -a "${CI_TEST_LOG_FILE}"
# Each suite runs from its own directory under _build/default: a
# stanza's paths are written relative to the stanza, and dune's own
# runtest action stands there too, so anywhere else reads a
# different tree than the nightly lane does.
repo_root="${PWD}"
for suite_path in "${suites[@]}"; do
  suite_dir="$(dirname "${suite_path}")"
  suite="$(basename "${suite_path}")"
  cd "${repo_root}/_build/default/${suite_dir}"
  suite_env=()
  env_lines=$(python3 "${stanza_env_reader}" --dir "${suite_dir}" "${suite}")
  while IFS= read -r pair; do
    if [ -n "${pair}" ]; then suite_env+=("${pair}"); fi
  done <<< "${env_lines}"
  log "[targeted] ${suite_path}: stanza env ${suite_env[*]+${suite_env[*]}}"
  log "[targeted] ${suite_path}: start $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  started=$(date +%s)
  rc=0
  # ${arr[@]+"${arr[@]}"} expands an empty array to nothing under
  # set -u on every bash, not only 4.4 and later.
  env MASC_BASE_PATH= GRAPHQL_API_KEY= ZAI_API_KEY= \
      MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED=false \
      MASC_KEEPER_DOCKER_PLAYGROUND=false \
      ALCOTEST_VERBOSE=1 ${suite_env[@]+"${suite_env[@]}"} \
      "${timeout_command}" -s TERM -k "${TARGET_SUITE_KILL_GRACE_SEC}" "${TARGET_SUITE_TIMEOUT_SEC}" \
      "./${suite}.exe" 2>&1 | tee -a "${CI_TEST_LOG_FILE}" || rc=$?
  elapsed=$(( $(date +%s) - started ))
  # timeout(1) exits 124 when TERM ended the command and 137
  # when it took the KILL after the grace.
  case "${rc}" in
    0)   log "[targeted] ${suite_path}: OK in ${elapsed}s" ;;
    124|137)
         log "[targeted] ${suite_path}: TIMEOUT exit ${rc} after ${elapsed}s;" \
             "the hung case is the one after the last [OK] line above"
         status=1 ;;
    *)   log "[targeted] ${suite_path}: FAIL exit ${rc} in ${elapsed}s"
         status=1 ;;
  esac
done
exit "${status}"
