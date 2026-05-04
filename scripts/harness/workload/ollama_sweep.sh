#!/usr/bin/env bash
# Phase 1a-1: model sweep harness on top of ollama_direct_bench.sh.
#
# Iterates a model list, runs workloads W1/W2/W3, evicts the previous
# runner via ISOLATE chaining. Default workload set is W1,W2,W3.
#
# Usage:
#   scripts/harness/workload/ollama_sweep.sh           # defaults to pulled models
#   MODELS="m1 m2 m3" scripts/harness/workload/ollama_sweep.sh
#   WORKLOADS="W1,W3" MODELS="qwen3:8b" ./ollama_sweep.sh
#
# Env knobs:
#   MODELS       space-separated model ids (default: ollama list output)
#   WORKLOADS    comma-separated W1|W2|W3 (default: W1,W2,W3)
#   THINK        true|false (default: false — main goal is decode tok/s)
#   NUM_PREDICT  output cap (default: 200)
#   OUT_PATH     JSONL aggregate path (default: data/bench/ollama-direct/sweep-<ts>.jsonl)
#
# Notes:
#   - First model gets cold load. Subsequent: prev model evicted via
#     keep_alive:0 then new model loaded. Memory contention isolated.
#   - Each row in output is one (model, workload) measurement.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

OUT_PATH="${OUT_PATH:-${REPO_ROOT}/data/bench/ollama-direct/sweep-${TS}.jsonl}"
WORKLOADS="${WORKLOADS:-W1,W2,W3}"
THINK="${THINK:-false}"
NUM_PREDICT="${NUM_PREDICT:-200}"

if [ -z "${MODELS:-}" ]; then
  if ! command -v ollama >/dev/null 2>&1; then
    echo "ollama CLI required to enumerate pulled models, or set MODELS env" >&2
    exit 1
  fi
  MODELS="$(ollama list 2>/dev/null | awk 'NR>1 {print $1}' | tr '\n' ' ')"
fi

mkdir -p "$(dirname "$OUT_PATH")"
: >"$OUT_PATH"

echo "sweep_start ts=$TS workloads=$WORKLOADS think=$THINK num_predict=$NUM_PREDICT"
echo "models=$MODELS"
echo "out=$OUT_PATH"
echo

PREV=""
total_start="$(date +%s)"

for model in $MODELS; do
  IFS=',' read -r -a wl_arr <<<"$WORKLOADS"
  for wl in "${wl_arr[@]}"; do
    wl="$(printf '%s' "$wl" | tr -d ' ')"
    [ -z "$wl" ] && continue

    isolate="false"
    if [ -n "$PREV" ] && [ "$PREV" != "$model" ]; then
      isolate="true"
      # Warmup the new model with a tiny prompt before the actual measurement.
      # Without this, large MLX models (>=64GB) sometimes return zero-metadata
      # responses on the first measured request post cold load. Warmup costs
      # ~load_time + 100ms; measurement reliability gain is large.
      curl -sS --max-time 90 -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg m "$model" '{model:$m, prompt:"ping", stream:false, think:false, options:{num_predict:1}}')" \
        http://localhost:11434/api/generate >/dev/null 2>&1 || true
    fi

    row_start="$(date +%s)"
    echo "→ $model $wl  (isolate=$isolate prev=$PREV)"
    set +e
    THINK="$THINK" NUM_PREDICT="$NUM_PREDICT" ISOLATE="$isolate" PREV_MODEL="$PREV" \
      "${SCRIPT_DIR}/ollama_direct_bench.sh" "$model" "$wl" "$OUT_PATH" 2>&1 | grep -E '^(decode|prefill|wallclock|response_head|done_reason|FAIL)' || true
    rc=$?
    set -e
    row_end="$(date +%s)"
    echo "  done in $((row_end - row_start))s rc=$rc"
    echo
    PREV="$model"
  done
done

# Final eviction (free RAM after sweep)
if [ -n "$PREV" ]; then
  curl -sS --max-time 10 -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg m "$PREV" '{model:$m, keep_alive:0}')" \
    http://localhost:11434/api/generate >/dev/null 2>&1 || true
fi

total_end="$(date +%s)"
elapsed=$((total_end - total_start))

echo "sweep_done elapsed=${elapsed}s"
echo "rows=$(wc -l <"$OUT_PATH" | tr -d ' ')"
echo "summary:"
jq -s '
  group_by(.model) | map({
    model: .[0].model,
    runs: length,
    avg_decode_tok_per_sec: (
      [.[] | .decode_tok_per_sec // empty] |
      if length > 0 then (add / length) else null end
    ),
    avg_prefill_tok_per_sec: (
      [.[] | .prefill_tok_per_sec // empty] |
      if length > 0 then (add / length) else null end
    ),
    avg_wallclock_ms: (
      [.[] | .wallclock_ms // empty] |
      if length > 0 then (add / length) else null end
    ),
    workloads: [.[] | {w: .workload, dur_ms: .wallclock_ms, tok_s: .decode_tok_per_sec, len: .response_len}]
  })
' "$OUT_PATH"
echo "out=$OUT_PATH"
