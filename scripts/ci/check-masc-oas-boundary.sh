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

# 1b. OAS API surface fingerprint must not contain MASC domain back-references.
#     This check is self-contained (no OAS checkout required) and fails
#     fast if the pinned OAS API surface gains public MASC vocabulary.
echo "=== Scan: OAS API surface fingerprint for MASC domain back-references ==="
oas_surface_file="scripts/oas-api-surface.json"
if [[ -f "${oas_surface_file}" ]]; then
  masc_in_surface=$(python3 - "${oas_surface_file}" <<'PYEOF'
import json, re, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
hits = []
# Match concrete MASC-owned public vocabulary as identifier components.
# OAS may expose generic agent/runtime/tool vocabulary, but not MASC product
# semantics such as keeper, fusion, or board concepts.
patterns = [
    ("masc_", re.compile(r"(?i)masc_")),
    ("keeper", re.compile(r"(?i)(^|[^a-z0-9])keeper([^a-z0-9]|$)")),
    ("fusion", re.compile(r"(?i)(^|[^a-z0-9])fusion([^a-z0-9]|$)")),
    ("board", re.compile(r"(?i)(^|[^a-z0-9])board([^a-z0-9]|$)")),
]
for section, items in d.get("surfaces", {}).items():
    if isinstance(items, list):
        for item in items:
            text = str(item)
            for name, pattern in patterns:
                if pattern.search(text):
                    hits.append(f"{section}: {item} ({name})")
for h in hits:
    print(h)
PYEOF
)
  if [[ -n "$masc_in_surface" ]]; then
    echo "FAIL: OAS API surface fingerprint contains MASC domain back-reference(s):"
    echo "$masc_in_surface"
    echo "  OAS must not learn MASC keeper/fusion/board vocabulary."
    echo "  repair: remove the MASC-specific item from OAS, refresh scripts/oas-api-surface.json"
    exit_code=1
  else
    echo "PASS: OAS API surface fingerprint contains no MASC domain back-references"
  fi
else
  echo "WARN: ${oas_surface_file} not found; skipping fingerprint MASC domain back-reference check"
fi

# 2. MASC using Oas_worker raw/internal interfaces instead of public API.
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
