#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${TOOL_CALL_QUALITY_OUT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/tool-call-quality.XXXXXX")}"
CASES_PATH="${TOOL_CALL_QUALITY_CASES_PATH:-${ROOT_DIR}/benchmarks/data/tool_call_quality_cases.json}"
EVIDENCE_PATH="${TOOL_CALL_QUALITY_EVIDENCE_PATH:-${ROOT_DIR}/test/fixtures/tool_call_quality_benchmark/evidence_runs.json}"
FORMAT="${TOOL_CALL_QUALITY_FORMAT:-json}"
VIEW="${TOOL_CALL_QUALITY_VIEW:-provider-model-keeper}"
REQUIRE_ROUTE_EVIDENCE="${TOOL_CALL_QUALITY_REQUIRE_ROUTE_EVIDENCE:-1}"
CLI_EXE="${ROOT_DIR}/_build/default/test/tool_call_quality_benchmark_cli.exe"

MODELS="${TOOL_CALL_QUALITY_MODELS:-}"
KEEPERS="${TOOL_CALL_QUALITY_KEEPERS:-bench-analyst,bench-executor,bench-verifier}"

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/harness_tool_call_quality.sh [--cases PATH] [--evidence PATH] [--format json|csv]
                                       [--view provider-model-keeper|provider-model|keeper]
                                       [--artifact-dir DIR] [--models CSV] [--keepers CSV]
                                       [--no-require-route-evidence]

Aggregates an existing evidence JSON file through the benchmark CLI.
EOF
}

ensure_cli_built() {
  (
    cd "${ROOT_DIR}"
    if [[ "${TOOL_CALL_QUALITY_SKIP_BUILD:-0}" != "1" || ! -x "${CLI_EXE}" ]]; then
      scripts/dune-local.sh build ./test/tool_call_quality_benchmark_cli.exe >/dev/null
    fi
  )
}

run_evidence_summary() {
  local args
  ensure_cli_built
  mkdir -p "${OUT_DIR}"
  (
    cd "${ROOT_DIR}"
    args=(
      --cases "${CASES_PATH}"
      --evidence "${EVIDENCE_PATH}"
      --format "${FORMAT}"
      --view "${VIEW}"
      --artifact-dir "${OUT_DIR}"
    )
    if [[ -n "${MODELS}" ]]; then
      args+=(--models "${MODELS}")
    fi
    if [[ -n "${KEEPERS}" ]]; then
      args+=(--keepers "${KEEPERS}")
    fi
    if [[ "${REQUIRE_ROUTE_EVIDENCE}" == "1" ]]; then
      args+=(--require-route-evidence)
    fi
    "${CLI_EXE}" "${args[@]}"
  )
  printf '\nartifact_dir=%s\n' "${OUT_DIR}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cases)
      CASES_PATH="$2"
      shift 2
      ;;
    --evidence)
      EVIDENCE_PATH="$2"
      shift 2
      ;;
    --format)
      FORMAT="$2"
      shift 2
      ;;
    --view)
      VIEW="$2"
      shift 2
      ;;
    --artifact-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --models)
      MODELS="$2"
      shift 2
      ;;
    --keepers)
      KEEPERS="$2"
      shift 2
      ;;
    --require-route-evidence)
      REQUIRE_ROUTE_EVIDENCE=1
      shift
      ;;
    --no-require-route-evidence)
      REQUIRE_ROUTE_EVIDENCE=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
done

mkdir -p "${OUT_DIR}"

run_evidence_summary
