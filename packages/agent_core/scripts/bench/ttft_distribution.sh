#!/usr/bin/env bash
#
# scripts/bench/ttft_distribution.sh
# RFC-OAS-020 PR-1b — TTFT (Time To First Token) distribution bench.
#
# What this measures
# ------------------
# This script measures **TTFB** (Time To First *Byte* of body) as a
# transport-level proxy for TTFT.  TTFB is the closest curl can
# observe without parsing the SSE stream; for the strict RFC-OAS-020
# TTFT definition (time to first chunk with a non-empty user-visible
# delta — text / reasoning / tool-call), use the in-process
# capture point added in PR-1a (Streaming_summary.ttft_ms via
# on_telemetry).
#
# Differences between TTFB (this script) and TTFT (PR-1a in-process):
#
# - **Anthropic**: TTFB ≈ time to MessageStart (prelude). TTFT ≈
#   time to first ContentBlockDelta. Anthropic typically has a
#   measurable gap between the two — TTFB will UNDER-report TTFT.
# - **OpenAI-compat / Gemini / GLM / Ollama**: TTFB ≈ TTFT (first
#   chunk is usually the first content delta). The two metrics
#   typically agree within ~5 ms.
#
# Therefore the SLO targets in §3.3 of the RFC are calibrated using
# the in-process TTFT capture, not this script.  This script is for
# operational sanity checks and external smoke tests.
#
# Usage
# -----
#   $ scripts/bench/ttft_distribution.sh anthropic 100 claude-opus-4-7
#   $ scripts/bench/ttft_distribution.sh llama-local 100 qwen3.5-9b
#   $ scripts/bench/ttft_distribution.sh glm 100 glm-4-plus
#
# Output (last line is JSON, prior lines are per-iter samples on stderr):
#   {"provider":"anthropic","model":"...","iter":100,"p50_ms":...,"p95_ms":...,"max_ms":...,"mean_ms":...,"std_ms":...}
#
# Environment
# -----------
#   ANTHROPIC_API_KEY  — required when provider=anthropic
#   GLM_API_KEY        — required when provider=glm
#   LLAMA_URL          — override default http://localhost:8085/v1/chat/completions
#   GLM_URL            — override default https://open.bigmodel.cn/...
#
# Exit codes
# ----------
#   0  bench completed; JSON summary on stdout
#   1  unknown provider / missing env var / curl failure rate > 10 %

set -euo pipefail

PROVIDER="${1:-anthropic}"
ITER="${2:-100}"
MODEL="${3:-}"

# Provider-specific request config. Each block sets:
#   URL, MODEL (if not overridden), AUTH_HEADER, BODY, EXTRA_HEADERS
case "$PROVIDER" in
  anthropic)
    URL="https://api.anthropic.com/v1/messages"
    MODEL="${MODEL:-claude-opus-4-7}"
    : "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY not set}"
    AUTH_HEADER="x-api-key: ${ANTHROPIC_API_KEY}"
    BODY="{\"model\":\"${MODEL}\",\"max_tokens\":50,\"messages\":[{\"role\":\"user\",\"content\":\"Say hi.\"}],\"stream\":true}"
    EXTRA_HEADERS=(-H "anthropic-version: 2023-06-01" -H "Content-Type: application/json")
    ;;
  llama-local)
    URL="${LLAMA_URL:-http://localhost:8085/v1/chat/completions}"
    MODEL="${MODEL:-qwen3.5-9b}"
    AUTH_HEADER="Authorization: Bearer dummy"
    BODY="{\"model\":\"${MODEL}\",\"max_tokens\":50,\"messages\":[{\"role\":\"user\",\"content\":\"Say hi.\"}],\"stream\":true}"
    EXTRA_HEADERS=(-H "Content-Type: application/json")
    ;;
  glm)
    URL="${GLM_URL:-https://open.bigmodel.cn/api/paas/v4/chat/completions}"
    MODEL="${MODEL:-glm-4-plus}"
    : "${GLM_API_KEY:?GLM_API_KEY not set}"
    AUTH_HEADER="Authorization: Bearer ${GLM_API_KEY}"
    BODY="{\"model\":\"${MODEL}\",\"max_tokens\":50,\"messages\":[{\"role\":\"user\",\"content\":\"Say hi.\"}],\"stream\":true}"
    EXTRA_HEADERS=(-H "Content-Type: application/json")
    ;;
  *)
    echo "ERROR: unknown provider '$PROVIDER' (expected: anthropic | llama-local | glm)" >&2
    exit 1
    ;;
esac

echo "# TTFT bench (TTFB proxy): provider=${PROVIDER} model=${MODEL} iter=${ITER}" >&2
echo "# Note: this measures TTFB, not strict TTFT. See header for details." >&2

samples=()
failures=0
for i in $(seq 1 "$ITER") ; do
  # -N            no buffering (start emitting as soon as body bytes arrive)
  # -o /dev/null  discard body
  # -w time_starttransfer  time from start of request to first body byte
  # --max-time 30 hard cap per request
  ttfb_s=$(curl -sS -N -o /dev/null \
    -w "%{time_starttransfer}" \
    --max-time 30 \
    -X POST "$URL" \
    -H "$AUTH_HEADER" \
    "${EXTRA_HEADERS[@]}" \
    -d "$BODY" 2>/dev/null) || ttfb_s=""

  if [[ -z "$ttfb_s" || "$ttfb_s" == "0.000000" ]] ; then
    failures=$((failures + 1))
    echo "# iter=${i} FAILED" >&2
    continue
  fi

  ttfb_ms=$(awk -v t="$ttfb_s" 'BEGIN { printf "%.3f", t * 1000 }')
  samples+=("$ttfb_ms")
  echo "${i} ${ttfb_ms}" >&2
done

n=${#samples[@]}
if [ "$n" -eq 0 ] ; then
  echo "ERROR: zero successful samples" >&2
  exit 1
fi

# Allow up to 10 % failures before refusing to report; above that the
# distribution is too biased toward the survivors to be meaningful.
failure_rate=$(awk -v f="$failures" -v t="$ITER" 'BEGIN { printf "%.2f", (f / t) * 100 }')
if awk -v fr="$failure_rate" 'BEGIN { exit (fr > 10.0 ? 0 : 1) }' ; then
  echo "ERROR: failure rate ${failure_rate} % > 10 %" >&2
  exit 1
fi

# Aggregate. Sort ascending, then compute p50/p95/max/mean/std via awk.
printf '%s\n' "${samples[@]}" \
  | sort -n \
  | awk -v provider="$PROVIDER" -v model="$MODEL" -v iter="$ITER" '
      BEGIN { sum = 0 }
      { a[NR] = $1 ; sum += $1 }
      END {
        n = NR
        p50_idx = int(n * 0.50) ; if (p50_idx < 1) p50_idx = 1
        p95_idx = int(n * 0.95) ; if (p95_idx < 1) p95_idx = 1
        p50 = a[p50_idx]
        p95 = a[p95_idx]
        pmax = a[n]
        mean = sum / n
        var = 0
        for (i = 1 ; i <= n ; i++) var += (a[i] - mean) ^ 2
        std = sqrt(var / n)
        printf "{\"provider\":\"%s\",\"model\":\"%s\",\"iter\":%d,\"samples\":%d,\"p50_ms\":%.2f,\"p95_ms\":%.2f,\"max_ms\":%.2f,\"mean_ms\":%.2f,\"std_ms\":%.2f,\"metric\":\"ttfb_proxy\"}\n", provider, model, iter, n, p50, p95, pmax, mean, std
      }
    '
