#!/usr/bin/env bash
# usage: ./run_matrix.sh [arms-csv] [attempts]
# env: BENCH_MODEL (default kimi/kimi-for-coding — Task 9가 실제 id 확정),
#      CONCURRENCY (default 2)
set -euo pipefail
cd "$(dirname "$0")"

ARMS_CSV="${1:-a,b,c,e,f,h}"
K="${2:-3}"
MODEL="${BENCH_MODEL:-kimi/kimi-for-coding}"
TS="$(date +%Y%m%d-%H%M%S)"

TASK_ARGS=()
while IFS= read -r t; do
  [[ -n "$t" ]] && TASK_ARGS+=( -i "$t" )
done < suite/mini-suite.txt

for arm in ${ARMS_CSV//,/ }; do
  job="arm-${arm}-${TS}"
  if [[ "$arm" == "a" ]]; then
    uv run harbor run -d terminal-bench@2.0 --agent terminus-2 \
      --model "$MODEL" -k "$K" -n "${CONCURRENCY:-2}" \
      -o results/jobs --job-name "$job" "${TASK_ARGS[@]}"
  else
    uv run harbor run -d terminal-bench@2.0 \
      --agent agents.masc_agent:MascAgent --model "$MODEL" \
      --ak "arm=$arm" -k "$K" -n "${CONCURRENCY:-2}" \
      -o results/jobs --job-name "$job" "${TASK_ARGS[@]}"
  fi
done
uv run python aggregate.py "results/jobs" > "results/summary-${TS}.csv"
echo "wrote results/summary-${TS}.csv"
