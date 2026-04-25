#!/usr/bin/env bash
# CI gate: MASC->OAS boundary violation detection (BND).
# Meta-issue: #9519
#
# CONTRACT:
#   - Upstream OAS must remain coordinator-agnostic. When an OAS
#     checkout provides scripts/check-sdk-independence.sh, delegate to it.
#   - MASC must use OAS public APIs (Agent.run, context_injector, etc.)
#     rather than reimplementing lifecycle/retry/budget logic.
#   - MASC must not touch OAS internal modules (Oas_worker internals,
#     Oas_response raw constructors, etc.)

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

exit_code=0
oas_repo_explicit=0

resolve_oas_repo() {
  if [[ -n "${AGENT_SDK_LOCAL_REPO:-}" ]]; then
    oas_repo_explicit=1
    if git -C "${AGENT_SDK_LOCAL_REPO}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      (cd "${AGENT_SDK_LOCAL_REPO}" && pwd -P)
      return 0
    fi
    echo "AGENT_SDK_LOCAL_REPO is not a git checkout: ${AGENT_SDK_LOCAL_REPO}" >&2
    return 2
  fi

  local repo_parent
  repo_parent="$(dirname "$(pwd)")"
  local candidates=(
    "${repo_parent}/oas"
    "${HOME:-}/me/workspace/yousleepwhen/oas"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" ]] \
      && git -C "$candidate" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      (cd "$candidate" && pwd -P)
      return 0
    fi
  done

  return 1
}

# 1. Upstream OAS SDK should not learn MASC coordinator vocabulary.
echo "=== Scan: Upstream OAS SDK independence ==="
if oas_repo="$(resolve_oas_repo)"; then
  echo "OAS checkout: ${oas_repo}"
  if [[ -f "${oas_repo}/scripts/check-sdk-independence.sh" ]]; then
    if (cd "$oas_repo" && bash scripts/check-sdk-independence.sh); then
      echo "PASS"
    else
      if [[ "$oas_repo_explicit" == "1" || "${MASC_STRICT_OAS_INDEPENDENCE:-0}" == "1" ]]; then
        echo "FAIL: upstream OAS SDK independence check failed"
        exit_code=1
      else
        echo "WARN: auto-detected sibling OAS checkout failed SDK independence; set AGENT_SDK_LOCAL_REPO or MASC_STRICT_OAS_INDEPENDENCE=1 to make this blocking"
      fi
    fi
  else
    echo "WARN: ${oas_repo}/scripts/check-sdk-independence.sh not found; skipping upstream SDK scan"
    if [[ "${MASC_STRICT_OAS_INDEPENDENCE:-0}" == "1" ]]; then
      echo "FAIL: MASC_STRICT_OAS_INDEPENDENCE=1 requires upstream SDK scan"
      exit_code=1
    fi
  fi
else
  resolve_status=$?
  if [[ "$resolve_status" -eq 2 ]]; then
    echo "FAIL: explicit OAS checkout override is invalid"
    exit_code=1
  else
    echo "WARN: no OAS checkout found; skipping upstream SDK scan"
    if [[ "${MASC_STRICT_OAS_INDEPENDENCE:-0}" == "1" ]]; then
      echo "FAIL: MASC_STRICT_OAS_INDEPENDENCE=1 requires an OAS checkout"
      exit_code=1
    fi
  fi
fi

# 2. MASC files that reimplement OAS patterns (heuristic)
#    We look for OAS lifecycle patterns inside MASC modules that should
#    instead call Oas_agent.run or similar.
echo "=== Scan: MASC lifecycle reimplementation heuristic ==="
# List of patterns that indicate MASC is doing OAS's job
masc_matches=$(
  rg -n --type ml \
    -e 'retry_count' \
    -e 'backoff_ms' \
    -e 'budget_remaining' \
    -e 'context_window' \
    -e 'token_budget' \
    lib/keeper/ lib/masc_*.ml 2>/dev/null || true
)
if [ -n "$masc_matches" ]; then
  echo "WARN: MASC files contain OAS-reserved concepts (verify they call OAS, not reimplement):"
  echo "$masc_matches" | head -20
fi

# 3. MASC using Oas_worker internal constructors instead of public API
echo "=== Scan: MASC -> Oas_worker internal constructor use ==="
internal_matches=$(
  rg -n --type ml \
    -e 'Oas_response\.' \
    -e 'Oas_worker\.run_raw' \
    -e 'Oas_worker\.internal' \
    lib/keeper/ lib/masc_*.ml 2>/dev/null || true
)
if [ -n "$internal_matches" ]; then
  echo "WARN: MASC uses Oas_worker internal-looking identifiers:"
  echo "$internal_matches" | head -20
fi

if [ "$exit_code" -eq 0 ]; then
  echo "=== BND gate: PASS ==="
else
  echo "=== BND gate: FAIL ==="
fi

exit "$exit_code"
