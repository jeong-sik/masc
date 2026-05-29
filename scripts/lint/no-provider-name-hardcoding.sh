#!/usr/bin/env bash
# Guard the Provider_adapter removal follow-up: provider/model identity must
# not keep growing in the MASC-owned runtime projection boundary.
#
# This is intentionally narrower than a repo-wide string grep.  Terms like
# "claude", "gemini", or "auto" are valid in auth, agent naming, voice persona,
# and unrelated operator UX code.  The migration risk tracked by
# docs/PROVIDER-ADAPTER-REMOVAL-PLAN.md is the provider-runtime/cascade bridge
# learning concrete provider identity after Provider_adapter was removed.
#
# Ratchet model: per-file literal COUNT ceilings (path:max_count).  Counts are
# position-independent, so moving code within a file never trips the gate.
#   - current > ceiling  -> fail (drift up: a new literal was added)
#   - current < ceiling  -> pass + advisory (lower the ceiling in this PR)
#   - current == ceiling -> pass
#
# Why count-based: the previous `path:line:literal` ledger broke on every code
# move.  A literal shifting one line read as new+stale at once, so any unrelated
# refactor in the scanned files turned this gate red and buried real drift in
# noise.  See the cascade->Runtime migration churn (2026-05).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALLOWLIST="${ROOT}/scripts/lint/no-provider-name-hardcoding.allowlist"

MODE="--fail"
case "${1:---fail}" in
  --fail|"") MODE="--fail" ;;
  --print) MODE="--print" ;;
  -h|--help)
    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "Usage: $0 [--fail|--print]" >&2
    exit 2
    ;;
esac

for tool in rg sed grep; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[no-provider-name-hardcoding] required tool missing: $tool" >&2
    exit 2
  }
done

cd "$ROOT"

SCAN_FILES=(
  "lib/provider_runtime_projection.ml"
  "lib/cascade/cascade_runtime.ml"
)

LITERAL_PATTERN='"(claude|codex|gemini|llama|llama\.cpp|llamacpp|openrouter|openai_compat|ollama|custom|auto)"'

# Read the per-file ceiling from the allowlist ledger (path:max_count).
# Missing entry => ceiling 0 (any literal in a newly-scanned file is drift up).
ceiling_for() {
  local file="$1" escaped value
  escaped="${file//./\\.}"
  value="$(sed -E 's/#.*//' "$ALLOWLIST" 2>/dev/null \
    | grep -E "^${escaped}:" \
    | head -1 \
    | sed -E 's/^[^:]+:[[:space:]]*([0-9]+).*/\1/')"
  [[ "$value" =~ ^[0-9]+$ ]] && printf '%s' "$value" || printf '0'
}

fail=0
print_keys=""

printf "%-44s %8s %8s\n" "file" "current" "ceiling"
echo "----------------------------------------------------------------"
for file in "${SCAN_FILES[@]}"; do
  if [[ -f "$file" ]]; then
    current="$(rg -o "$LITERAL_PATTERN" "$file" 2>/dev/null | grep -c . || true)"
  else
    current=0
  fi
  ceiling="$(ceiling_for "$file")"
  printf "%-44s %8s %8s\n" "$file" "$current" "$ceiling"

  if (( current > ceiling )); then
    echo "[no-provider-name-hardcoding] DRIFT UP: $file has $current provider/model literals (ceiling $ceiling)." >&2
    echo "  A new provider/model name literal was hardcoded. Route truth through runtime bindings, or" >&2
    echo "  if intentional debt, raise the ceiling in $ALLOWLIST with a replacement-task link." >&2
    fail=1
  elif (( current < ceiling )); then
    echo "[no-provider-name-hardcoding] RATCHET DOWN available: $file now $current (ceiling $ceiling)." >&2
    echo "  A literal was removed. Lower the ceiling in $ALLOWLIST in this PR to lock the gain (advisory)." >&2
  fi

  if [[ "$MODE" = "--print" && -f "$file" ]]; then
    print_keys+="$(rg --line-number -o "$LITERAL_PATTERN" "$file" 2>/dev/null | sed "s#^#  - $file:#" || true)"$'\n'
  fi
done

if [[ "$MODE" = "--print" ]]; then
  echo
  echo "[no-provider-name-hardcoding] current literals:"
  printf '%s' "$print_keys" | sed '/^$/d'
  exit 0
fi

if (( fail != 0 )); then
  exit 1
fi

echo
echo "[no-provider-name-hardcoding] OK"
