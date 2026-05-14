#!/usr/bin/env bash
# Provider_adapter removal ratchet.
#
# Phase 0 of docs/PROVIDER-ADAPTER-REMOVAL-PLAN.md freezes the legacy
# Provider_adapter boundary while later PRs move provider/model truth to OAS
# catalog/capability surfaces. Existing debt may shrink; it must not grow.
#
# Usage:
#   bash scripts/lint/provider-adapter-removal-ratchet.sh
#   bash scripts/lint/provider-adapter-removal-ratchet.sh --print
#   bash scripts/lint/provider-adapter-removal-ratchet.sh --regenerate

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CALLER_BASELINE="${ROOT}/scripts/lint/provider-adapter-removal-ratchet.callers"
EXPORT_BASELINE="${ROOT}/scripts/lint/provider-adapter-removal-ratchet.exports"

for tool in rg sort comm mktemp wc tr sed; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[provider-adapter-removal-ratchet] required tool missing: $tool" >&2
    exit 1
  }
done

current_callers() {
  (
    set +o pipefail
    cd "$ROOT"
    rg -l 'Provider_adapter\.' lib test bin 2>/dev/null | sort -u
  )
}

baseline_callers() {
  sed -E 's/#.*//; s/[[:space:]]+$//; /^$/d' "$CALLER_BASELINE" | sort -u
}

current_export_count() {
  (
    set +o pipefail
    cd "$ROOT"
    rg -n '^(val|type|module) ' lib/provider_adapter.mli 2>/dev/null | wc -l | tr -d ' '
  )
}

baseline_export_count() {
  sed -E 's/#.*//; s/[[:space:]]//g; /^$/d' "$EXPORT_BASELINE" | head -n 1
}

print_counts() {
  local caller_tmp baseline_tmp
  caller_tmp="$(mktemp -t provider-adapter-callers.current.XXXXXX)"
  baseline_tmp="$(mktemp -t provider-adapter-callers.baseline.XXXXXX)"
  trap 'rm -f "$caller_tmp" "$baseline_tmp"' RETURN

  current_callers >"$caller_tmp"
  baseline_callers >"$baseline_tmp"

  printf "%-32s %9s  %9s\n" "metric" "current" "baseline"
  echo "------------------------------------------------------"
  printf "%-32s %9d  %9d\n" \
    "provider_adapter_callers" \
    "$(wc -l <"$caller_tmp" | tr -d ' ')" \
    "$(wc -l <"$baseline_tmp" | tr -d ' ')"
  printf "%-32s %9d  %9d\n" \
    "provider_adapter_mli_exports" \
    "$(current_export_count)" \
    "$(baseline_export_count)"
}

regenerate() {
  current_callers >"$CALLER_BASELINE"
  current_export_count >"$EXPORT_BASELINE"
  echo "[provider-adapter-removal-ratchet] regenerated baselines"
}

check() {
  local caller_tmp baseline_tmp new_tmp drift=0
  caller_tmp="$(mktemp -t provider-adapter-callers.current.XXXXXX)"
  baseline_tmp="$(mktemp -t provider-adapter-callers.baseline.XXXXXX)"
  new_tmp="$(mktemp -t provider-adapter-callers.new.XXXXXX)"
  trap 'rm -f "$caller_tmp" "$baseline_tmp" "$new_tmp"' RETURN

  current_callers >"$caller_tmp"
  baseline_callers >"$baseline_tmp"
  comm -13 "$baseline_tmp" "$caller_tmp" >"$new_tmp"

  if [[ -s "$new_tmp" ]]; then
    echo "[provider-adapter-removal-ratchet] DRIFT UP: new Provider_adapter callers" >&2
    sed 's/^/  - /' "$new_tmp" >&2
    echo "  route through OAS-owned provider catalog/capability surfaces or a MASC-local overlay instead." >&2
    drift=1
  fi

  local current_exports baseline_exports
  current_exports="$(current_export_count)"
  baseline_exports="$(baseline_export_count)"
  if (( current_exports > baseline_exports )); then
    echo "[provider-adapter-removal-ratchet] DRIFT UP: Provider_adapter.mli exports current=${current_exports} baseline=${baseline_exports}" >&2
    echo "  do not expand the legacy Provider_adapter API; add the replacement boundary instead." >&2
    drift=1
  fi

  return "$drift"
}

case "${1:-}" in
  --print)
    print_counts
    ;;
  --regenerate)
    regenerate
    ;;
  "")
    print_counts
    if check; then
      echo
      echo "[provider-adapter-removal-ratchet] OK"
      exit 0
    else
      echo
      echo "[provider-adapter-removal-ratchet] FAIL - current exceeds baseline" >&2
      echo "  intentional increases are not allowed in Phase 0; split the caller" >&2
      echo "  through the new runtime overlay or OAS provider catalog first." >&2
      exit 2
    fi
    ;;
  *)
    echo "Usage: $0 [--print|--regenerate]" >&2
    exit 1
    ;;
esac
