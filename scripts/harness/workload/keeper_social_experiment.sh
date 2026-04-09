#!/usr/bin/env bash
# Keeper Social Experiment Harness
# - Runs baseline/protocol social rounds across keeper cohort
# - Captures turn logs + per-arm summary + optional A/B delta

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
MASC_URL="${MASC_URL:-http://127.0.0.1:8935}"
MCP_URL="${MCP_URL:-${MASC_URL%/}/mcp}"

RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
RUN_DIR="${RUN_DIR:-$ROOT_DIR/logs/social_experiment/$RUN_ID}"
RAW_DIR="$RUN_DIR/raw"
SNAP_DIR="$RUN_DIR/snapshots"
mkdir -p "$RUN_DIR" "$RAW_DIR" "$SNAP_DIR"

DRY_RUN="${DRY_RUN:-0}"
ROUNDS="${ROUNDS:-6}"
ARMS="${ARMS:-baseline,protocol}"
MODEL_CASCADE="${MODEL_CASCADE:-glm:auto}"
TOPIC="${TOPIC:-영속 에이전트의 기억/계승/자율성 안정화 전략}"
SLEEP_BETWEEN_CALLS_SEC="${SLEEP_BETWEEN_CALLS_SEC:-1}"
CLEANUP="${CLEANUP:-0}"
NAME_PREFIX="${NAME_PREFIX:-socexp}"

if ! command -v jq >/dev/null 2>&1; then
  echo "[ERROR] jq is required" >&2
  exit 1
fi

if [[ "$DRY_RUN" != "1" ]] && ! command -v curl >/dev/null 2>&1; then
  echo "[ERROR] curl is required" >&2
  exit 1
fi

DRY_TICK=0

log() {
  echo "[$(date '+%H:%M:%S')] $*"
}

now_ms() {
  local s
  s="$(date +%s)"
  echo "$((s * 1000 + (RANDOM % 1000)))"
}

mcp_call() {
  local tool_name="$1"
  local args_json="$2"

  if [[ "$DRY_RUN" == "1" ]]; then
    case "$tool_name" in
      masc_keeper_up)
        local n
        n="$(echo "$args_json" | jq -r '.name // "unknown"')"
        jq -cn --arg n "$n" \
          '{jsonrpc:"2.0",id:1,result:{content:[{type:"text",text:({simulated:true,name:$n,ok:true}|tojson)}]}}'
        ;;
      masc_keeper_msg)
        DRY_TICK=$((DRY_TICK + 1))
        local n m r latency ratio compacted handoff reply
        n="$(echo "$args_json" | jq -r '.name // "unknown"')"
        m="$(echo "$args_json" | jq -r '.message // ""')"
        r="$(echo "$m" | sed -n 's/^Round \([0-9][0-9]*\).*/\1/p')"
        r="${r:-1}"
        latency=$((80 + (DRY_TICK % 40)))
        ratio="$(awk -v t="$DRY_TICK" 'BEGIN { printf "%.3f", (t % 10) / 10.0 }')"
        compacted=$((DRY_TICK % 3 == 0 ? 1 : 0))
        handoff=$((DRY_TICK % 7 == 0 ? 1 : 0))
        if [[ "$n" == *"moderator"* ]]; then
          reply="[dry-run moderator] consensus: memory-first; dissent: latency-vs-quality; next: tighten budget."
        else
          reply="[dry-run $n] proposal/critique/action for round $r on topic."
        fi
        jq -cn \
          --arg n "$n" \
          --arg reply "$reply" \
          --argjson latency "$latency" \
          --argjson ratio "$ratio" \
          --argjson compacted "$compacted" \
          --argjson handoff "$handoff" \
          '{
             jsonrpc:"2.0",id:1,result:{content:[{type:"text",text:( {
               simulated:true,
               name:$n,
               generation:0,
               model_used:"simulated:dry-run",
               latency_ms:$latency,
               context_ratio:$ratio,
               compacted:($compacted==1),
               handoff:{performed:($handoff==1)},
               reply:$reply
             }|tojson)}]}
           }'
        ;;
      masc_keeper_down|masc_keeper_status)
        jq -cn '{jsonrpc:"2.0",id:1,result:{content:[{type:"text",text:"{\"ok\":true}"}]}}'
        ;;
      *)
        jq -cn --arg t "$tool_name" '{jsonrpc:"2.0",id:1,error:{code:-32601,message:("dry-run unsupported tool: "+$t)}}'
        ;;
    esac
    return 0
  fi

  local payload
  local raw
  payload="$(jq -cn \
    --arg tool "$tool_name" \
    --argjson args "$args_json" \
    '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:$tool,arguments:$args}}')"
  raw="$(curl -sS --http2-prior-knowledge "$MCP_URL" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "MCP-Protocol-Version: 2025-11-25" \
    -d "$payload")"

  if echo "$raw" | jq -e . >/dev/null 2>&1; then
    echo "$raw"
    return 0
  fi

  # Streamable HTTP may respond as SSE framing:
  # retry: ...
  # event: message
  # data: {...jsonrpc...}
  local sse_data
  sse_data="$(echo "$raw" | awk '/^data: /{sub(/^data: /, ""); print}' | tail -n1)"
  if [[ -n "$sse_data" ]] && echo "$sse_data" | jq -e . >/dev/null 2>&1; then
    echo "$sse_data"
    return 0
  fi

  echo "$raw"
}

tool_text() {
  local resp="$1"
  local err text
  err="$(echo "$resp" | jq -r '.error.message // empty')"
  if [[ -n "$err" ]]; then
    echo "[ERROR] tool call failed: $err" >&2
    return 1
  fi
  text="$(echo "$resp" | jq -r '.result.content[0].text // empty')"
  if [[ -z "$text" ]]; then
    echo "[ERROR] missing tool text payload" >&2
    return 1
  fi
  echo "$text"
}

json_or_empty() {
  local raw="$1"
  echo "$raw" | jq -c . 2>/dev/null || true
}

build_models_json() {
  jq -cn --arg csv "$MODEL_CASCADE" \
    '$csv | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0))'
}

mk_keeper_name() {
  local arm="$1"
  local role="$2"
  local run_short
  run_short="$(echo "$RUN_ID" | tr -cd '0-9' | tail -c 6)"
  echo "${NAME_PREFIX}-${arm}-${role}-${run_short}" | tr '[:upper:]' '[:lower:]'
}

create_keeper() {
  local name="$1"
  local soul="$2"
  local goal="$3"
  local instructions="$4"
  local models_json="$5"

  local args resp text
  args="$(jq -cn \
    --arg name "$name" \
    --arg goal "$goal" \
    --arg instructions "$instructions" \
    --arg soul "$soul" \
    --argjson models "$models_json" \
    '{
      name:$name,
      goal:$goal,
      instructions:$instructions,
      soul_profile:$soul,
      models:$models,
      auto_handoff:true,
      handoff_threshold:0.82,
      handoff_cooldown_sec:180,
      context_budget:0.60
    }')"
  resp="$(mcp_call "masc_keeper_up" "$args")"
  text="$(tool_text "$resp")"
  if [[ "$text" == "❌"* ]]; then
    echo "[ERROR] keeper_up failed for $name: $text" >&2
    return 1
  fi
}

send_keeper_msg() {
  local name="$1"
  local message="$2"
  local args resp text
  args="$(jq -cn --arg name "$name" --arg message "$message" '{name:$name,message:$message}')"
  resp="$(mcp_call "masc_keeper_msg" "$args")"
  echo "$resp" > "$RAW_DIR/msg_${name}_$(now_ms).json"
  text="$(tool_text "$resp")"
  echo "$text"
}

maybe_cleanup_keeper() {
  local name="$1"
  local args resp
  args="$(jq -cn --arg name "$name" '{name:$name,remove_meta:true,remove_session:true}')"
  resp="$(mcp_call "masc_keeper_down" "$args" || true)"
  echo "$resp" > "$RAW_DIR/down_${name}.json"
}

maybe_snapshot_dashboard() {
  local arm="$1"
  local round="$2"
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  curl -sS --http2-prior-knowledge "${MASC_URL%/}/api/v1/dashboard" > "$SNAP_DIR/dashboard_${arm}_r${round}.json" || true
}

summarize_arm() {
  local arm="$1"
  local turns_file="$2"
  local out_file="$3"

  jq -s --arg arm "$arm" '
    def avg(xs): if (xs|length) == 0 then 0 else (xs|add) / (xs|length) end;
    {
      arm: $arm,
      total_turns: length,
      success_turns: (map(select(.ok == true)) | length),
      success_rate: (if length == 0 then 0 else ((map(select(.ok == true)) | length) / length) end),
      avg_latency_ms: avg(map(select(.latency_ms != null) | .latency_ms)),
      p95_latency_ms: (
        [map(select(.latency_ms != null) | .latency_ms)[]] as $lat
        | if ($lat|length) == 0 then 0
          else ($lat | sort | .[((length * 95 / 100) | floor)])
          end
      ),
      avg_context_ratio: avg(map(select(.context_ratio != null) | .context_ratio)),
      handoff_events: (map(select(.handoff == true)) | length),
      compaction_events: (map(select(.compacted == true)) | length),
      reply_diversity_ratio: (
        if length == 0 then 0
        else ((map(.reply_preview) | unique | length) / length)
        end
      ),
      dissent_mentions: (
        map(select((.reply_preview // "") | test("반대|이견|disagree|however|but"; "i"))) | length
      )
    }' "$turns_file" > "$out_file"
}

generate_delta() {
  local baseline_file="$1"
  local protocol_file="$2"
  local out_file="$3"
  jq -n \
    --slurpfile a "$baseline_file" \
    --slurpfile b "$protocol_file" '
    {
      baseline: $a[0],
      protocol: $b[0],
      delta: {
        success_rate: ($b[0].success_rate - $a[0].success_rate),
        avg_latency_ms: ($b[0].avg_latency_ms - $a[0].avg_latency_ms),
        p95_latency_ms: ($b[0].p95_latency_ms - $a[0].p95_latency_ms),
        handoff_events: ($b[0].handoff_events - $a[0].handoff_events),
        compaction_events: ($b[0].compaction_events - $a[0].compaction_events),
        reply_diversity_ratio: ($b[0].reply_diversity_ratio - $a[0].reply_diversity_ratio),
        dissent_mentions: ($b[0].dissent_mentions - $a[0].dissent_mentions)
      }
    }' > "$out_file"
}

main() {
  local models_json
  models_json="$(build_models_json)"

  jq -n \
    --arg run_id "$RUN_ID" \
    --arg run_dir "$RUN_DIR" \
    --arg mcp_url "$MCP_URL" \
    --arg topic "$TOPIC" \
    --arg arms "$ARMS" \
    --arg model_cascade "$MODEL_CASCADE" \
    --arg dry_run "$DRY_RUN" \
    --arg rounds "$ROUNDS" \
    '{
      run_id:$run_id,
      run_dir:$run_dir,
      mcp_url:$mcp_url,
      topic:$topic,
      arms:$arms,
      model_cascade:$model_cascade,
      dry_run:($dry_run=="1"),
      rounds:($rounds|tonumber),
      started_at:(now|todateiso8601)
    }' > "$RUN_DIR/manifest.json"

  log "run_id=$RUN_ID"
  log "run_dir=$RUN_DIR"
  log "arms=$ARMS rounds=$ROUNDS dry_run=$DRY_RUN"

  local baseline_summary=""
  local protocol_summary=""

  IFS=',' read -r -a arm_list <<< "$ARMS"
  for arm in "${arm_list[@]}"; do
    arm="$(echo "$arm" | xargs)"
    [[ -z "$arm" ]] && continue
    log "arm=$arm setup"

    local archivist skeptic builder dreamer moderator
    archivist="$(mk_keeper_name "$arm" "archivist")"
    skeptic="$(mk_keeper_name "$arm" "skeptic")"
    builder="$(mk_keeper_name "$arm" "builder")"
    dreamer="$(mk_keeper_name "$arm" "dreamer")"
    moderator="$(mk_keeper_name "$arm" "moderator")"
    local keepers=("$archivist" "$skeptic" "$builder" "$dreamer" "$moderator")
    local worker_keepers=("$archivist" "$skeptic" "$builder" "$dreamer")

    create_keeper "$archivist" "relationship" \
      "대화의 핵심 결론과 근거를 장기기억 가능한 구조로 정리한다." \
      "항상 증거와 결정 이유를 남긴다." \
      "$models_json"
    create_keeper "$skeptic" "safety" \
      "취약점, 모순, 과장된 주장, 실행 리스크를 먼저 찾는다." \
      "반박은 구체적 실패 시나리오 중심으로 한다." \
      "$models_json"
    create_keeper "$builder" "delivery" \
      "실행 가능한 단계와 검증 절차를 도출한다." \
      "모든 제안은 테스트 가능한 액션으로 끝낸다." \
      "$models_json"
    create_keeper "$dreamer" "research" \
      "새로운 가설과 실험 변수를 제안한다." \
      "아이디어는 측정 가능한 지표와 함께 제시한다." \
      "$models_json"
    create_keeper "$moderator" "balanced" \
      "이견을 조정하고 합의안/쟁점을 분리해 요약한다." \
      "요약은 짧고 실행 지향적으로 작성한다." \
      "$models_json"

    local turns_file="$RUN_DIR/arm_${arm}_turns.jsonl"
    : > "$turns_file"
    local board_summary="(no summary yet)"

    for ((round=1; round<=ROUNDS; round++)); do
      log "arm=$arm round=$round start"
      local digest_lines=()

      for keeper in "${worker_keepers[@]}"; do
        local prompt
        if [[ "$arm" == "protocol" ]]; then
          prompt="$(cat <<EOF
Round $round social protocol.
Topic: $TOPIC
Previous summary:
$board_summary

Output rules:
1) Proposal: one concrete claim
2) Critique: one likely failure or disagreement point
3) Action: one measurable next step
Keep it concise.
EOF
)"
        else
          prompt="$(cat <<EOF
Round $round discussion.
Topic: $TOPIC
Previous summary:
$board_summary

Please provide your best next contribution for the group.
EOF
)"
        fi

        local raw_text raw_json ok latency ratio compacted handoff gen reply preview
        ok=true
        raw_text="$(send_keeper_msg "$keeper" "$prompt" || true)"
        if [[ -z "$raw_text" ]] || [[ "$raw_text" == "❌"* ]]; then
          ok=false
        fi
        raw_json="$(json_or_empty "$raw_text")"

        latency="$(echo "$raw_json" | jq -r '.latency_ms // empty' 2>/dev/null || true)"
        ratio="$(echo "$raw_json" | jq -r '.context_ratio // empty' 2>/dev/null || true)"
        compacted="$(echo "$raw_json" | jq -r '.compacted // false' 2>/dev/null || true)"
        handoff="$(echo "$raw_json" | jq -r '.handoff.performed // false' 2>/dev/null || true)"
        gen="$(echo "$raw_json" | jq -r '.generation // empty' 2>/dev/null || true)"
        reply="$(echo "$raw_json" | jq -r '.reply // empty' 2>/dev/null || true)"
        if [[ -z "$reply" ]]; then
          reply="$raw_text"
        fi
        preview="$(echo "$reply" | tr '\n' ' ' | cut -c1-220)"

        jq -cn \
          --arg arm "$arm" \
          --argjson round "$round" \
          --arg keeper "$keeper" \
          --arg kind "worker" \
          --argjson ok "$( [[ "$ok" == "true" ]] && echo true || echo false )" \
          --argjson latency "${latency:-null}" \
          --argjson ratio "${ratio:-null}" \
          --argjson compacted "$( [[ "$compacted" == "true" ]] && echo true || echo false )" \
          --argjson handoff "$( [[ "$handoff" == "true" ]] && echo true || echo false )" \
          --argjson generation "${gen:-null}" \
          --arg preview "$preview" \
          --arg ts "$(date -Iseconds)" \
          '{
            ts:$ts, arm:$arm, round:$round, keeper:$keeper, kind:$kind, ok:$ok,
            latency_ms:$latency, context_ratio:$ratio, compacted:$compacted,
            handoff:$handoff, generation:$generation, reply_preview:$preview
          }' >> "$turns_file"

        digest_lines+=("- [$keeper] $preview")
        sleep "$SLEEP_BETWEEN_CALLS_SEC"
      done

      local digest joined_digest mod_prompt mod_raw mod_json mod_reply mod_preview
      joined_digest="$(printf "%s\n" "${digest_lines[@]}")"
      mod_prompt="$(cat <<EOF
Round $round moderator synthesis.
Topic: $TOPIC
Worker outputs:
$joined_digest

Return:
1) Consensus (1-2 lines)
2) Dissent (1-2 lines)
3) Next action (1 line, measurable)
EOF
)"

      mod_raw="$(send_keeper_msg "$moderator" "$mod_prompt" || true)"
      mod_json="$(json_or_empty "$mod_raw")"
      mod_reply="$(echo "$mod_json" | jq -r '.reply // empty' 2>/dev/null || true)"
      if [[ -z "$mod_reply" ]]; then
        mod_reply="$mod_raw"
      fi
      mod_preview="$(echo "$mod_reply" | tr '\n' ' ' | cut -c1-220)"
      board_summary="$(echo "$mod_reply" | cut -c1-1200)"

      jq -cn \
        --arg arm "$arm" \
        --argjson round "$round" \
        --arg keeper "$moderator" \
        --arg kind "moderator" \
        --arg preview "$mod_preview" \
        --arg ts "$(date -Iseconds)" \
        --argjson ok true \
        --argjson latency "$(echo "$mod_json" | jq -r '.latency_ms // null' 2>/dev/null || echo null)" \
        --argjson ratio "$(echo "$mod_json" | jq -r '.context_ratio // null' 2>/dev/null || echo null)" \
        --argjson compacted "$( [[ "$(echo "$mod_json" | jq -r '.compacted // false' 2>/dev/null || echo false)" == "true" ]] && echo true || echo false )" \
        --argjson handoff "$( [[ "$(echo "$mod_json" | jq -r '.handoff.performed // false' 2>/dev/null || echo false)" == "true" ]] && echo true || echo false )" \
        --argjson generation "$(echo "$mod_json" | jq -r '.generation // null' 2>/dev/null || echo null)" \
        '{
          ts:$ts, arm:$arm, round:$round, keeper:$keeper, kind:$kind, ok:$ok,
          latency_ms:$latency, context_ratio:$ratio, compacted:$compacted,
          handoff:$handoff, generation:$generation, reply_preview:$preview
        }' >> "$turns_file"

      maybe_snapshot_dashboard "$arm" "$round"
      sleep "$SLEEP_BETWEEN_CALLS_SEC"
    done

    local arm_summary="$RUN_DIR/summary_${arm}.json"
    summarize_arm "$arm" "$turns_file" "$arm_summary"
    log "arm=$arm summary => $arm_summary"

    if [[ "$arm" == "baseline" ]]; then
      baseline_summary="$arm_summary"
    elif [[ "$arm" == "protocol" ]]; then
      protocol_summary="$arm_summary"
    fi

    if [[ "$CLEANUP" == "1" ]]; then
      for k in "${keepers[@]}"; do
        maybe_cleanup_keeper "$k"
      done
    fi
  done

  if [[ -n "$baseline_summary" && -n "$protocol_summary" ]]; then
    generate_delta "$baseline_summary" "$protocol_summary" "$RUN_DIR/ab_delta.json"
    log "A/B delta => $RUN_DIR/ab_delta.json"
  fi

  jq --arg ended "$(date -Iseconds)" '.ended_at=$ended' "$RUN_DIR/manifest.json" > "$RUN_DIR/manifest.json.tmp"
  mv "$RUN_DIR/manifest.json.tmp" "$RUN_DIR/manifest.json"

  log "done. outputs:"
  log " - $RUN_DIR/manifest.json"
  ls -1 "$RUN_DIR" | sed 's/^/ - /'
}

main "$@"
