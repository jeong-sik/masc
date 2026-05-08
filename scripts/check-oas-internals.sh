#!/usr/bin/env bash
# Guard masc-mcp from reaching past the agent_sdk public surface.
#
# Symmetric counterpart to OAS's scripts/check-sdk-independence.sh
# (oas does not depend on masc-mcp; masc-mcp does not reach into
# oas internals).
#
# Tiers:
#   strict   (default, fail-on-match):
#     - `Agent_sdk__*` mangled internal-module references in lib/
#       (these would only appear if a caller bypassed the wrapped
#       library by going through the dune __ -mangled name directly).
#
#   warn     (--include-internals):
#     - `Llm_provider.Provider_kind` qualified module access
#       outside lib/provider_kind_resolver.{ml,mli}
#       (informational; allowed uses include serialization, type
#       annotations, local-module aliases, and comments).
#     - `Llm_provider.Constants` qualified access outside
#       lib/oas_compat/ and lib/provider_kind_resolver.{ml,mli}
#       (informational; cascade subsystem currently legitimately
#       reads default inference params).
#
#   strict-internals (--strict-internals):
#     promote warn-tier matches to failures. Use after baseline
#     occurrences have been tagged with `(* boundary-allow:<reason> *)`.
#
# Permanently excluded scopes: _build/, .worktrees/, .masc/playground/,
# test/ (test fixtures legitimately reference internals for boundary
# round-trip checks).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

include_internals=0
strict_internals=0
for arg in "$@"; do
  case "$arg" in
    --include-internals) include_internals=1 ;;
    --strict-internals)  include_internals=1; strict_internals=1 ;;
    -h|--help)
      sed -n '1,32p' "$0"
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

# Common rg excludes.
RG_BASE_FLAGS=(
  --type-add 'ocaml:*.{ml,mli}'
  -t ocaml
  -g '!_build/**'
  -g '!.worktrees/**'
  -g '!.masc/playground/**'
)

# Filter: skip OCaml comment-leading lines and lines tagged with
# `boundary-allow`. Mirrors OAS's check-sdk-independence.sh heuristic.
filter_noise() {
  awk -F':' '
    {
      idx = index($0, ":")
      rest = substr($0, idx + 1)
      idx2 = index(rest, ":")
      content = substr(rest, idx2 + 1)
      sub(/^[[:space:]]+/, "", content)
      if (content ~ /^\*/) next
      if (content ~ /^\(\*/) next
      if ($0 ~ /boundary-allow/) next
      print $0
    }
  '
}

scan_strict_agent_sdk_internal() {
  # Catch `Agent_sdk__Foo` (the dune wrapped-library mangled name).
  # Direct legit access uses `Agent_sdk.Foo` instead.
  local matches
  matches="$(rg -n 'Agent_sdk__[A-Za-z_]' lib/ "${RG_BASE_FLAGS[@]}" 2>/dev/null | filter_noise || true)"
  if [[ -n "$matches" ]]; then
    echo "FAIL [strict]: Agent_sdk__ mangled internal reference (use Agent_sdk.X instead)" >&2
    echo "$matches" >&2
    return 1
  fi
  return 0
}

scan_warn_provider_kind_external() {
  # Provider_kind qualified access outside provider_kind_resolver.
  local matches
  matches="$(rg -n 'Llm_provider\.Provider_kind|\bProvider_kind\.' lib/ "${RG_BASE_FLAGS[@]}" 2>/dev/null \
    | grep -v 'lib/provider_kind_resolver\.' \
    | filter_noise || true)"
  if [[ -n "$matches" ]]; then
    if [[ "$strict_internals" -eq 1 ]]; then
      echo "FAIL [internals]: Llm_provider.Provider_kind raw access outside provider_kind_resolver" >&2
    else
      echo "WARN [internals]: Llm_provider.Provider_kind raw access outside provider_kind_resolver" >&2
    fi
    echo "$matches" >&2
    return 1
  fi
  return 0
}

scan_warn_constants_external() {
  # Llm_provider.Constants outside oas_compat / provider_kind_resolver.
  local matches
  matches="$(rg -n 'Llm_provider\.Constants' lib/ "${RG_BASE_FLAGS[@]}" 2>/dev/null \
    | grep -v 'lib/oas_compat/' \
    | grep -v 'lib/provider_kind_resolver\.' \
    | filter_noise || true)"
  if [[ -n "$matches" ]]; then
    if [[ "$strict_internals" -eq 1 ]]; then
      echo "FAIL [internals]: Llm_provider.Constants raw access outside oas_compat / provider_kind_resolver" >&2
    else
      echo "WARN [internals]: Llm_provider.Constants raw access outside oas_compat / provider_kind_resolver" >&2
    fi
    echo "$matches" >&2
    return 1
  fi
  return 0
}

overall_fail=0
if ! scan_strict_agent_sdk_internal; then
  overall_fail=1
fi

if [[ "$include_internals" -eq 1 ]]; then
  pk_ok=1
  if ! scan_warn_provider_kind_external; then pk_ok=0; fi
  cn_ok=1
  if ! scan_warn_constants_external; then cn_ok=0; fi
  if [[ "$strict_internals" -eq 1 && ( "$pk_ok" -eq 0 || "$cn_ok" -eq 0 ) ]]; then
    overall_fail=1
  fi
fi

if [[ "$overall_fail" -ne 0 ]]; then
  echo "OAS-internals check failed" >&2
  exit 1
fi

echo "OK: OAS-internals check passed"
