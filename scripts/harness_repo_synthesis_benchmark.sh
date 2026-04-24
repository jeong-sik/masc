#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_SYNTHESIS_BENCH_OUT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/repo-synthesis-bench.XXXXXX")}"
SUMMARY_PATH="${OUT_DIR}/summary.json"
BENCH_EXE="${ROOT_DIR}/_build/default/test/test_repo_synthesis_benchmark.exe"

mkdir -p "${OUT_DIR}"

(
  cd "${ROOT_DIR}"
  if [ "${REPO_SYNTHESIS_SKIP_BUILD:-0}" != "1" ] || [ ! -x "${BENCH_EXE}" ]; then
    scripts/dune-local.sh build ./test/test_repo_synthesis_benchmark.exe >/dev/null
  fi
  "${BENCH_EXE}" >"${SUMMARY_PATH}"
)

cat "${SUMMARY_PATH}"
printf '\nsummary=%s\n' "${SUMMARY_PATH}"
