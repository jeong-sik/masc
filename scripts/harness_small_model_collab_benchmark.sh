#!/usr/bin/env bash
# Small Model Collaboration Benchmark
# 9B x 4 team session vs 35B x 1 단독 — repo_synthesis 질문셋
#
# Usage:
#   LLAMA_PRESET=qwen35    ./scripts/harness_small_model_collab_benchmark.sh --phase baseline
#   LLAMA_PRESET=qwen35-9b ./scripts/harness_small_model_collab_benchmark.sh --phase collab
#   ./scripts/harness_small_model_collab_benchmark.sh --phase report
#
# Env:
#   MCP_URL          - MASC MCP endpoint (default: http://127.0.0.1:8935/mcp)
#   LLAMA_URL        - llama-server endpoint (default: http://127.0.0.1:8085)
#   REPEAT           - repetitions per condition (default: 5)
#   BENCHMARK_DIR    - output directory (default: .masc/benchmarks/small-model-collab)
#   COLLAB_AGENTS    - number of agents for collab condition (default: 4)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/scripts/harness/lib/mcp_jsonrpc.sh"

MCP_URL="${MCP_URL:-http://127.0.0.1:8935/mcp}"
LLAMA_URL="${LLAMA_URL:-http://127.0.0.1:8085}"
REPEAT="${REPEAT:-5}"
COLLAB_AGENTS="${COLLAB_AGENTS:-4}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"
BENCHMARK_DIR="${BENCHMARK_DIR:-${ROOT_DIR}/.masc/benchmarks/small-model-collab/${RUN_ID}}"
QUESTION_SET="${ROOT_DIR}/benchmark/repo_synthesis_question_set.json"
MCP_SESSION_ID="collab-bench-${RUN_ID}"
MCP_CURL_EXTRA_ARGS="${MCP_CURL_EXTRA_ARGS:---http2-prior-knowledge}"
HTTP_TIMEOUT_SEC="${HTTP_TIMEOUT_SEC:-300}"

PHASE=""

usage() {
  echo "Usage: $0 --phase <baseline|collab|both|report>"
  echo ""
  echo "  baseline  Run 35B single-agent baseline (REPEAT times)"
  echo "  collab    Run 9B x COLLAB_AGENTS team session (REPEAT times)"
  echo "  both      Run baseline then collab sequentially"
  echo "  report    Generate comparison report from existing results"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) PHASE="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --repeat) REPEAT="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[ -z "$PHASE" ] && usage

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

# --- Helpers ---

check_llama() {
  local resp
  resp=$(curl -sf "${LLAMA_URL}/health" 2>/dev/null || echo "")
  if [ -z "$resp" ]; then
    echo "ERROR: llama-server not responding at ${LLAMA_URL}" >&2
    echo "Start with: LLAMA_PRESET=<preset> ~/me/scripts/llama-server.sh" >&2
    exit 1
  fi
  local model
  model=$(curl -sf "${LLAMA_URL}/v1/models" 2>/dev/null | jq -r '.data[0].id // "unknown"')
  echo "[bench] llama-server model: ${model}"
}

check_masc() {
  local health
  health=$(curl -sf "http://127.0.0.1:8935/health" 2>/dev/null | jq -r '.status // "unknown"')
  if [ "$health" != "ok" ]; then
    echo "ERROR: MASC server not healthy at :8935 (status=${health})" >&2
    exit 1
  fi
  echo "[bench] MASC server: ok"
}

save_config() {
  mkdir -p "$BENCHMARK_DIR"
  local model
  model=$(curl -sf "${LLAMA_URL}/v1/models" 2>/dev/null | jq -r '.data[0].id // "unknown"')
  cat > "${BENCHMARK_DIR}/config.json" << CONF
{
  "run_id": "${RUN_ID}",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "question_set": "${QUESTION_SET}",
  "question_count": $(jq 'length' "$QUESTION_SET"),
  "repeat": ${REPEAT},
  "collab_agents": ${COLLAB_AGENTS},
  "llama_url": "${LLAMA_URL}",
  "llama_model": "${model}"
}
CONF
  echo "[bench] Config saved: ${BENCHMARK_DIR}/config.json"
}

timestamp_ms() {
  python3 -c "import time; print(int(time.time()*1000))"
}

# --- Baseline Phase ---
# Single agent answers each question using MASC tool dispatch.
# Reuses repo_synthesis_benchmark infrastructure.

run_baseline_single() {
  local iter="$1"
  local out_dir="${BENCHMARK_DIR}/baseline/run-${iter}"
  mkdir -p "$out_dir"

  echo "[baseline] iteration ${iter}/${REPEAT}"

  local questions
  questions=$(jq -c '.[]' "$QUESTION_SET")

  local scores="[]"

  while IFS= read -r q; do
    local qid
    qid=$(echo "$q" | jq -r '.question_id')
    local question_text
    question_text=$(echo "$q" | jq -r '.question')
    local gold_paths
    gold_paths=$(echo "$q" | jq -c '.gold_paths')
    local required_claims
    required_claims=$(echo "$q" | jq -c '.required_claims')

    echo "  [q] ${qid}: $(echo "$question_text" | head -c 60)..."

    local t0
    t0=$(timestamp_ms)

    # Call MASC broadcast as a proxy for agent answering the question.
    # In a real benchmark, this would go through the full agent loop.
    # For now, we call the llama completion directly and score the result.
    local answer
    answer=$(curl -sf "${LLAMA_URL}/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -d "{
        \"model\": \"default\",
        \"messages\": [
          {\"role\": \"system\", \"content\": \"You are a code analyst. Answer questions about the masc-mcp codebase. Cite specific file paths.\"},
          {\"role\": \"user\", \"content\": $(echo "$question_text" | jq -Rs .)}
        ],
        \"max_tokens\": 2048,
        \"temperature\": 0.3
      }" 2>/dev/null | jq -r '.choices[0].message.content // ""')

    local t1
    t1=$(timestamp_ms)
    local latency_ms=$(( t1 - t0 ))

    # Extract cited paths from answer (lines matching file paths)
    local cited_paths
    cited_paths=$(echo "$answer" | grep -oE '[a-zA-Z_/]+\.[a-z]+' | sort -u | jq -R . | jq -s .)

    # Extract claims (sentences containing key terms from required_claims)
    local claims
    claims=$(echo "$answer" | tr '.' '\n' | head -20 | jq -R . | jq -s .)

    # Score this question
    local score
    score=$(jq -n \
      --arg qid "$qid" \
      --argjson gold "$gold_paths" \
      --argjson required "$required_claims" \
      --argjson cited "$cited_paths" \
      --argjson claims "$claims" \
      --argjson latency "$latency_ms" \
      '{
        question_id: $qid,
        latency_ms: $latency,
        cited_paths: $cited,
        gold_paths: $gold,
        claims: $claims,
        required_claims: $required,
        evidence_precision: ([$cited[] | select(. as $c | $gold | index($c))] | length) / ([1, ($cited | length)] | max),
        claim_coverage: ([$required[] | select(. as $r | $claims | any(contains($r)))] | length) / ([1, ($required | length)] | max),
        unsupported_paths: [$cited[] | select(. as $c | $gold | index($c) | not)]
      }')

    scores=$(echo "$scores" | jq --argjson s "$score" '. + [$s]')
    echo "    latency=${latency_ms}ms precision=$(echo "$score" | jq '.evidence_precision') coverage=$(echo "$score" | jq '.claim_coverage')"
  done <<< "$questions"

  # Save iteration scores
  echo "$scores" | jq '.' > "${out_dir}/score.json"
  echo "[baseline] iteration ${iter} saved to ${out_dir}/score.json"
}

run_baseline() {
  echo "=== BASELINE PHASE (35B x 1) ==="
  check_llama
  check_masc
  save_config

  for i in $(seq 1 "$REPEAT"); do
    run_baseline_single "$i"
  done

  echo "[baseline] ${REPEAT} iterations complete."
}

# --- Collaboration Phase ---
# N agents answer questions via team session.

run_collab_single() {
  local iter="$1"
  local out_dir="${BENCHMARK_DIR}/collab/run-${iter}"
  mkdir -p "$out_dir"

  echo "[collab] iteration ${iter}/${REPEAT}"

  # Build participant list
  local participants=""
  for a in $(seq 1 "$COLLAB_AGENTS"); do
    [ -n "$participants" ] && participants="${participants},"
    participants="${participants}collab-agent-${a}-${RUN_ID}-${iter}"
  done

  local session_id="bench-collab-${RUN_ID}-${iter}"

  # Start team session via MASC
  local start_args
  start_args=$(jq -n \
    --arg goal "Answer repo_synthesis questions about masc-mcp codebase collaboratively" \
    --argjson duration 600 \
    --argjson min_agents "$COLLAB_AGENTS" \
    --arg scope "auto" \
    '{
      goal: $goal,
      duration_seconds: $duration,
      min_agents: $min_agents,
      execution_scope: $scope
    }')

  echo "  [collab] starting team session (${COLLAB_AGENTS} agents)..."
  local start_resp
  start_resp=$(mcp_call_tool "bench-start-${iter}" "masc_team_session_start" "$start_args" 2>/dev/null || echo "")

  if [ -z "$start_resp" ]; then
    echo "  [collab] WARN: team session start failed, skipping iteration ${iter}"
    echo '{"error": "session_start_failed"}' > "${out_dir}/score.json"
    return
  fi

  session_id=$(echo "$start_resp" | jq -r '.result.content[0].text // ""' | jq -r '.session_id // ""' 2>/dev/null || echo "")

  if [ -z "$session_id" ] || [ "$session_id" = "null" ]; then
    echo "  [collab] WARN: no session_id returned, skipping"
    echo '{"error": "no_session_id"}' > "${out_dir}/score.json"
    return
  fi

  echo "  [collab] session started: ${session_id}"

  # For each question, submit as a team session step
  local questions
  questions=$(jq -c '.[]' "$QUESTION_SET")

  local t0
  t0=$(timestamp_ms)

  while IFS= read -r q; do
    local qid
    qid=$(echo "$q" | jq -r '.question_id')
    local question_text
    question_text=$(echo "$q" | jq -r '.question')

    echo "  [collab] submitting question: ${qid}"

    local step_args
    step_args=$(jq -n \
      --arg sid "$session_id" \
      --arg note "$question_text" \
      '{session_id: $sid, step_type: "note", note: $note}')

    mcp_call_tool "bench-step-${qid}" "masc_team_session_step" "$step_args" >/dev/null 2>&1 || true
  done <<< "$questions"

  # Wait for session to process (simplified — real version would poll status)
  echo "  [collab] waiting for agents to process..."
  sleep 30

  # Get session status
  local status_args
  status_args=$(jq -n --arg sid "$session_id" '{session_id: $sid}')
  local status_resp
  status_resp=$(mcp_call_tool "bench-status-${iter}" "masc_team_session_status" "$status_args" 2>/dev/null || echo "")

  local t1
  t1=$(timestamp_ms)
  local total_latency=$(( t1 - t0 ))

  # Stop session and generate report
  local stop_args
  stop_args=$(jq -n --arg sid "$session_id" '{session_id: $sid, reason: "benchmark_complete", generate_report: true}')
  mcp_call_tool "bench-stop-${iter}" "masc_team_session_stop" "$stop_args" >/dev/null 2>&1 || true

  # Save results
  jq -n \
    --arg sid "$session_id" \
    --argjson latency "$total_latency" \
    --argjson agents "$COLLAB_AGENTS" \
    --arg status "$(echo "$status_resp" | jq -r '.result.content[0].text // "{}"' | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")" \
    '{
      session_id: $sid,
      total_latency_ms: $latency,
      agent_count: $agents,
      status: $status,
      note: "scoring requires OCaml bridge — manual inspection of session report for now"
    }' > "${out_dir}/score.json"

  echo "[collab] iteration ${iter} saved (session=${session_id}, ${total_latency}ms)"
}

run_collab() {
  echo "=== COLLABORATION PHASE (9B x ${COLLAB_AGENTS}) ==="
  check_llama
  check_masc
  save_config

  for i in $(seq 1 "$REPEAT"); do
    run_collab_single "$i"
  done

  echo "[collab] ${REPEAT} iterations complete."
}

# --- Report Phase ---

run_report() {
  echo "=== COMPARISON REPORT ==="

  if [ ! -d "${BENCHMARK_DIR}/baseline" ] && [ ! -d "${BENCHMARK_DIR}/collab" ]; then
    # Try to find latest run
    local latest
    latest=$(ls -td "${ROOT_DIR}/.masc/benchmarks/small-model-collab/"*/ 2>/dev/null | head -1)
    if [ -z "$latest" ]; then
      echo "ERROR: no benchmark results found" >&2
      exit 1
    fi
    BENCHMARK_DIR="${latest%/}"
    echo "[report] using latest: ${BENCHMARK_DIR}"
  fi

  echo ""
  echo "## Config"
  [ -f "${BENCHMARK_DIR}/config.json" ] && jq '.' "${BENCHMARK_DIR}/config.json"

  echo ""
  echo "## Baseline Results"
  if [ -d "${BENCHMARK_DIR}/baseline" ]; then
    for f in "${BENCHMARK_DIR}/baseline"/run-*/score.json; do
      [ -f "$f" ] || continue
      local run_name
      run_name=$(basename "$(dirname "$f")")
      echo "  ${run_name}:"
      jq -c '.[] | {question_id, evidence_precision, claim_coverage, latency_ms}' "$f" 2>/dev/null || echo "  (parse error)"
    done
  else
    echo "  (no baseline results)"
  fi

  echo ""
  echo "## Collaboration Results"
  if [ -d "${BENCHMARK_DIR}/collab" ]; then
    for f in "${BENCHMARK_DIR}/collab"/run-*/score.json; do
      [ -f "$f" ] || continue
      local run_name
      run_name=$(basename "$(dirname "$f")")
      echo "  ${run_name}:"
      jq '.' "$f" 2>/dev/null || echo "  (parse error)"
    done
  else
    echo "  (no collab results)"
  fi

  echo ""
  echo "## Summary"
  echo "(Full statistical comparison requires OCaml collab_benchmark_report — see docs/SMALL-MODEL-COLLAB-BENCHMARK.md)"
}

# --- Main ---

case "$PHASE" in
  baseline) run_baseline ;;
  collab)   run_collab ;;
  both)     run_baseline; echo ""; run_collab; echo ""; run_report ;;
  report)   run_report ;;
  *)        usage ;;
esac

echo ""
echo "[bench] Results: ${BENCHMARK_DIR}"
