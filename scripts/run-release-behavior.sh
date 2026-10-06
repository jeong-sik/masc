#!/usr/bin/env bash
# Run the same reviewed behavior selection locally and in a release candidate.
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET_SUITES=$(python3 scripts/ci/release_behavior.py --suites)
export TARGET_SUITES
if [ -z "${CI_TEST_LOG_FILE:-}" ]; then
  CI_TEST_LOG_FILE=$(mktemp "${TMPDIR:-/tmp}/masc-release-behavior.XXXXXX")
fi
export CI_TEST_LOG_FILE
# Both selected PTY stanzas depend on this binary. Compile it before starting
# the per-scenario hang guard; a cold compiler is not a failed interaction.
opam exec -- dune build --root . -j "${DUNE_JOBS:-2}" bin/masc_tui.exe 2>&1 | tee -a "${CI_TEST_LOG_FILE}"
exec bash scripts/ci-run-targeted-tests.sh
