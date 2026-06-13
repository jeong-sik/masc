#!/usr/bin/env bash
# Guard against reintroducing the retired scrape/backend family into active
# code, tests, dashboard code, specs, workflows, and operational scripts.
#
# Historical docs are intentionally out of scope. This gate protects the
# executable and prompt-facing surfaces that can break main again.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

MODE="--fail"
case "${1:---fail}" in
  --fail|"") MODE="--fail" ;;
  --print) MODE="--print" ;;
  -h|--help)
    sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "Usage: $0 [--fail|--print]" >&2
    exit 2
    ;;
esac

for tool in rg sort mktemp wc sed tr; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[no-retired-metrics-backend] required tool missing: $tool" >&2
    exit 2
  }
done

cd "$ROOT"

ACTIVE_ROOTS=(
  lib
  bin
  test
  scripts
  dashboard/src
  dashboard/test
  dashboard/docs
  specs
  .github
  infrastructure
)

existing_roots=()
for root in "${ACTIVE_ROOTS[@]}"; do
  [[ -e "$root" ]] && existing_roots+=("$root")
done

RETIRED_PATTERN='prometheus|promql|prometheus_sources|masc\.prometheus|Masc_prometheus|lib/prometheus|DS_PROMETHEUS|prometheusremotewrite'

current_tmp="$(mktemp -t retired-metrics-backend.current.XXXXXX)"
trap 'rm -f "$current_tmp"' EXIT

if [[ "${#existing_roots[@]}" -eq 0 ]]; then
  : >"$current_tmp"
else
  rg --with-filename --no-heading --line-number --color=never -i \
    --glob '!dashboard/node_modules/**' \
    --glob '!_build/**' \
    --glob '!scripts/lint/no-retired-metrics-backend.sh' \
    "$RETIRED_PATTERN" \
    "${existing_roots[@]}" \
    | sort -u >"$current_tmp" || true
fi

current_count="$(wc -l <"$current_tmp" | tr -d ' ')"

printf "%-36s %8s\n" "metric" "count"
echo "------------------------------------------------"
printf "%-36s %8s\n" "retired_metrics_backend_hits" "$current_count"

if [[ "$MODE" = "--print" ]]; then
  echo
  echo "[no-retired-metrics-backend] current keys:"
  sed 's/^/  - /' "$current_tmp"
  exit 0
fi

if [[ -s "$current_tmp" ]]; then
  echo
  echo "[no-retired-metrics-backend] DRIFT UP: retired metrics backend residue reappeared in active surface" >&2
  sed 's/^/  - /' "$current_tmp" >&2
  echo "  Keep the retired metrics backend out of active code, scripts, tests, specs, and workflows." >&2
  exit 1
fi

echo
echo "[no-retired-metrics-backend] OK"
