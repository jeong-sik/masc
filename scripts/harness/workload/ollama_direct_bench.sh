#!/usr/bin/env bash
# Phase 1a-1: direct Ollama API bench (no masc-mcp involvement).
#
# Purpose: isolate "1-hour trap" cause - is it (a) Ollama cold start, or
# (b) masc-mcp routing overhead? Measure (a) first, then layer (b) in
# Phase 1a-2.
#
# Inputs:  $1 = model id (e.g. "qwen3.6:27b-coding-nvfp4")
#          $2 = workload key (W1=code | W2=tool | W3=reason). Default W1.
#          $3 = output JSONL path. Default data/bench/ollama-direct/<ts>.jsonl
#
# Output JSONL row schema:
#   {model, workload, ts, load_ms, prefill_tok_per_sec, decode_tok_per_sec,
#    total_duration_ms, eval_count, prompt_eval_count, rss_runner_after_gb,
#    response_first_120, done_reason}
#
# Tok/s formulas (Ollama /api/generate response, ns):
#   prefill = prompt_eval_count / (prompt_eval_duration / 1e9)
#   decode  = eval_count        / (eval_duration        / 1e9)
#
# References:
#   docs.ollama.com/api  (durations are nanoseconds)

set -euo pipefail

MODEL="${1:-qwen3:8b}"
WORKLOAD="${2:-W1}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
OUT="${3:-${REPO_ROOT}/data/bench/ollama-direct/${TS}.jsonl}"

# Env knobs:
#   THINK         "true"|"false" — Ollama /api/generate think parameter for
#                 reasoning models (qwen3, deepseek-r1, gpt-oss, ...).
#                 Default false: measure raw decode without <think> overhead.
#   NUM_PREDICT   integer — output token cap. Default 200.
#   ISOLATE       "true"|"false" — call /api/generate with keep_alive:"5m"
#                 plus issue /api/generate {model:<prev>, keep_alive:0}
#                 to evict prior runner before bench. Default false.
#   PREV_MODEL    model id to evict when ISOLATE=true.
THINK="${THINK:-false}"
NUM_PREDICT="${NUM_PREDICT:-200}"
ISOLATE="${ISOLATE:-false}"
PREV_MODEL="${PREV_MODEL:-}"

mkdir -p "$(dirname "$OUT")"

case "$WORKLOAD" in
  W1) PROMPT='Implement Python function `parse_iso8601(s: str) -> datetime` with timezone awareness. Return only the function body and any imports.' ;;
  W2) PROMPT='You have a tool {"name":"read_file","args":{"path":"string"}}. Output JSON only: {"tool":"read_file","args":{"path":"README.md"}}. No prose.' ;;
  W3) PROMPT='A merchant sells apples 3 for $1, oranges 2 for $1. He sold 30 fruits for $13. How many apples? Show steps in <=5 lines.' ;;
  *)  echo "unknown workload: $WORKLOAD (use W1|W2|W3)" >&2; exit 2 ;;
esac

if [ "$ISOLATE" = "true" ] && [ -n "$PREV_MODEL" ]; then
  curl -sS --max-time 10 -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg m "$PREV_MODEL" '{model:$m, keep_alive:0}')" \
    http://localhost:11434/api/generate >/dev/null 2>&1 || true
fi

rss_before_kb="$(ps -A -o rss,command 2>/dev/null | awk '/[o]llama runner/ {sum+=$1} END {print sum+0}')"

REQ_BODY="$(jq -nc \
  --arg model "$MODEL" \
  --arg prompt "$PROMPT" \
  --argjson think "$THINK" \
  --argjson num_predict "$NUM_PREDICT" \
  '{model:$model, prompt:$prompt, stream:false, think:$think, options:{num_predict:$num_predict, temperature:0.2}}')"

req_start_ns="$(python3 -c 'import time;print(int(time.time()*1e9))')"
RESP="$(curl -sS --max-time 180 \
  -H 'Content-Type: application/json' \
  -d "$REQ_BODY" \
  http://localhost:11434/api/generate)"
req_end_ns="$(python3 -c 'import time;print(int(time.time()*1e9))')"

rss_after_kb="$(ps -A -o rss,command 2>/dev/null | awk '/[o]llama runner/ {sum+=$1} END {print sum+0}')"

if [ -z "$RESP" ] || ! printf '%s' "$RESP" | jq -e . >/dev/null 2>&1; then
  printf '{"model":"%s","workload":"%s","ts":"%s","error":"empty_or_invalid_response"}\n' \
    "$MODEL" "$WORKLOAD" "$TS" >> "$OUT"
  echo "FAIL: invalid response from ollama for $MODEL" >&2
  exit 1
fi

ROW="$(printf '%s' "$RESP" | jq -c \
  --arg model "$MODEL" \
  --arg workload "$WORKLOAD" \
  --arg ts "$TS" \
  --argjson rss_before "$rss_before_kb" \
  --argjson rss_after "$rss_after_kb" \
  --argjson req_start "$req_start_ns" \
  --argjson req_end "$req_end_ns" \
  --arg think "$THINK" \
  --arg isolate "$ISOLATE" \
  '{
    model: $model,
    workload: $workload,
    ts: $ts,
    think: ($think == "true"),
    isolate: ($isolate == "true"),
    load_ms: ((.load_duration // 0) / 1e6),
    prompt_eval_count: (.prompt_eval_count // 0),
    eval_count: (.eval_count // 0),
    prefill_tok_per_sec: (if (.prompt_eval_duration // 0) > 0 then (.prompt_eval_count / ((.prompt_eval_duration) / 1e9)) else null end),
    decode_tok_per_sec:  (if (.eval_duration // 0) > 0          then (.eval_count        / ((.eval_duration)        / 1e9)) else null end),
    total_duration_ms: ((.total_duration // 0) / 1e6),
    wallclock_ms: (($req_end - $req_start) / 1e6),
    rss_runner_before_gb: ($rss_before / 1024 / 1024),
    rss_runner_after_gb:  ($rss_after  / 1024 / 1024),
    response_first_120: ((.response // "") | .[0:120]),
    response_len: ((.response // "") | length),
    done_reason: (.done_reason // null)
  }')"

echo "$ROW" >> "$OUT"

printf '%s\n' "$ROW" | jq -r '
  "model:               \(.model)",
  "workload:            \(.workload)",
  "load_ms:             \(.load_ms | floor)",
  "prefill_tok_per_sec: \(if .prefill_tok_per_sec == null then "n/a" else (.prefill_tok_per_sec | floor | tostring) end)",
  "decode_tok_per_sec:  \(if .decode_tok_per_sec  == null then "n/a" else (.decode_tok_per_sec  | floor | tostring) end)",
  "total_duration_ms:   \(.total_duration_ms | floor)",
  "wallclock_ms:        \(.wallclock_ms | floor)",
  "rss_runner_after_gb: \(.rss_runner_after_gb)",
  "response_head:       \(.response_first_120)"
'
echo "log: $OUT"
