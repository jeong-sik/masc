#!/usr/bin/env bash
# CI gate: MASC->OAS boundary violation detection (BND).
# Meta-issue: #9519
#
# CONTRACT:
#   - Upstream OAS must remain agent-stream-agnostic. When an OAS
#     checkout provides scripts/check-sdk-independence.sh, delegate to it.
#     The pinned OAS API surface fingerprint (scripts/oas-api-surface.json)
#     is checked locally for masc_ back-references — no OAS checkout needed.
#   - MASC must use OAS public APIs (Agent.run, context_injector, etc.)
#     rather than reimplementing lifecycle/retry/budget logic.
#   - MASC must not touch OAS raw/internal interfaces (Oas_worker.run_raw,
#     Oas_worker.internal). Note: lib/oas_response.ml is a MASC-owned
#     facade module; using Oas_response.* from keeper is correct usage.

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

# 1. Upstream OAS SDK should not learn MASC agent stream vocabulary.
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

# 1b. OAS API surface fingerprint must not contain masc_ back-references.
#     This check is self-contained (no OAS checkout required) and fails
#     fast if the pinned OAS API surface gains any masc_-prefixed identifier.
echo "=== Scan: OAS API surface fingerprint for masc_ back-references ==="
oas_surface_file="scripts/oas-api-surface.json"
if [[ -f "${oas_surface_file}" ]]; then
  masc_in_surface=$(python3 - "${oas_surface_file}" <<'PYEOF'
import json, re, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
hits = []
# Match 'masc_' as a prefix or embedded component (case-insensitive).
# Using the underscore prevents false positives from unrelated words
# such as "damascus" or "mascara".
pattern = re.compile(r'(?i)masc_')
for section, items in d.get("surfaces", {}).items():
    if isinstance(items, list):
        for item in items:
            if pattern.search(str(item)):
                hits.append(f"{section}: {item}")
for h in hits:
    print(h)
PYEOF
)
  if [[ -n "$masc_in_surface" ]]; then
    echo "FAIL: OAS API surface fingerprint contains masc_ back-reference(s):"
    echo "$masc_in_surface"
    echo "  OAS must not learn MASC agent stream vocabulary."
    echo "  repair: remove the masc_-prefixed item from OAS, refresh scripts/oas-api-surface.json"
    exit_code=1
  else
    echo "PASS: OAS API surface fingerprint contains no masc_ back-references"
  fi
else
  echo "WARN: ${oas_surface_file} not found; skipping fingerprint masc_ back-reference check"
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
  head -20 <<< "$masc_matches"
fi

# 2b. Model capability truth must not flow from the legacy MASC runtime schema
#     into execution.  runtime.toml still has a compatibility parser for old
#     workspace documents, but the effective provider/model capability record
#     is owned by OAS and must be read from the materialized Provider_config.
echo "=== Scan: OAS model-capability SSOT ==="
legacy_capability_matches=$(
  rg -n --type ml --type mli \
    -e 'Runtime_schema\.model_capabilities' \
    -e 'model_capabilities_default' \
    -e '\.model\.capabilities' \
    -e '\.model\.thinking_support' \
    -e '\.model\.tools_support' \
    -e '\.model\.streaming' \
    -e 'supports_tool_choice_override_of_model_spec' \
    -e 'max_output_tokens_of_model_spec' \
    lib/runtime/runtime.ml \
    lib/runtime/runtime_adapter.ml \
    lib/runtime/runtime_agent.ml \
    lib/runtime/runtime_inference.ml \
    lib/keeper/ 2>/dev/null || true
)
if [ -n "$legacy_capability_matches" ]; then
  echo "FAIL: execution code consumes legacy MASC model capability declarations:"
  echo "$legacy_capability_matches"
  echo "  repair: resolve the concrete provider/model capability through OAS Provider_config"
  exit_code=1
else
  echo "PASS: execution code has no legacy MASC model-capability consumers"
fi

# 3. MASC using Oas_worker raw/internal interfaces instead of public API.
#    lib/oas_response.ml is a MASC-owned facade module; using
#    Oas_response.* from keeper code is the correct pattern (not a violation).
#    Only flag truly internal Oas_worker paths that bypass the public API.
echo "=== Scan: MASC -> Oas_worker raw/internal interface use ==="
internal_matches=$(
  rg -n --type ml \
    -e 'Oas_worker\.run_raw' \
    -e 'Oas_worker\.internal' \
    lib/keeper/ lib/masc_*.ml 2>/dev/null || true
)
if [ -n "$internal_matches" ]; then
  echo "FAIL: MASC uses Oas_worker raw/internal identifiers (route through Masc_oas_bridge or Oas_worker public API):"
  head -20 <<< "$internal_matches"
  exit_code=1
else
  echo "PASS: no Oas_worker raw/internal access in MASC keeper/bridge files"
fi

if [ "$exit_code" -eq 0 ]; then
  echo "=== BND gate: PASS ==="
else
  echo "=== BND gate: FAIL ==="
fi

exit "$exit_code"
