#!/usr/bin/env bash
# Guard MASC from reaching past the public surfaces of linked OAS libraries.
#
# Symmetric counterpart to OAS's scripts/check-sdk-independence.sh
# (oas does not depend on masc; masc does not reach into
# oas internals).
#
# Fails on any mangled internal-module reference for the three wrapped OAS
# libraries linked by lib/dune: agent_sdk, agent_sdk.base, and
# agent_sdk.llm_provider. Such a reference bypasses the public wrapper.
#
# Test support, fixtures, documentation, and archived sources are excluded.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      sed -n '1,14p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $arg" >&2
      exit 2
      ;;
  esac
done

if ! command -v rg >/dev/null 2>&1; then
  echo "OAS-internals check failed: ripgrep (rg) is required" >&2
  exit 1
fi

RG_BASE_FLAGS=(
  --type-add 'ocaml:*.{ml,mli}'
  -t ocaml
  -g '!_build/**'
  -g '!_build_codex_trpg/**'
  -g '!.worktrees/**'
  -g '!worktrees/**'
  -g '!.masc/playground/**'
  -g '!archive/**'
  -g '!dashboard_bonsai/**'
  -g '!docs/**'
  -g '!fixtures/**'
  -g '!test/**'
  -g '!test_lib/**'
  -g '!**/test/**'
  -g '!**/tests/**'
)

OAS_MANGLED_PREFIX_PATTERN='Agent_sdk__|Agent_sdk_base__|Llm_provider__'

scan_mangled_oas_internal() {
  local matches status
  if matches="$(rg -n "${RG_BASE_FLAGS[@]}" "$OAS_MANGLED_PREFIX_PATTERN" . 2>&1)"; then
    status=0
  else
    status=$?
  fi

  case "$status" in
    0) ;;
    1) matches="" ;;
    *)
      echo "OAS-internals check failed: ripgrep scan error (exit $status)" >&2
      echo "$matches" >&2
      return 1
      ;;
  esac

  if [[ -n "$matches" ]]; then
    echo "FAIL [strict]: OAS mangled internal reference (use the public wrapper instead)" >&2
    echo "$matches" >&2
    return 1
  fi
  return 0
}

if ! scan_mangled_oas_internal; then
  echo "OAS-internals check failed" >&2
  exit 1
fi

echo "OK: OAS-internals check passed"
