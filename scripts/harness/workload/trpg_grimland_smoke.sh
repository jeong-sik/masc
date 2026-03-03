#!/usr/bin/env bash
set -euo pipefail

MCP_URL="${MCP_URL:-http://127.0.0.1:8935/mcp}"
SESSION_ID="${SESSION_ID:-smoke-grimland-$(date +%s)}"
ROOM_ID="${ROOM_ID:-}"
ROUNDS="${ROUNDS:-2}"
RUN_ROUND="${RUN_ROUND:-0}"  # 0: bootstrap only, 1: include trpg.round.run
WORLD_PRESET_ID="${WORLD_PRESET_ID:-}"
DM_PRESET_ID="${DM_PRESET_ID:-}"
PARTY_SIZE="${PARTY_SIZE:-4}"
POOL_SIZE="${POOL_SIZE:-6}"
KEEPER_TAG="${KEEPER_TAG:-smoke-$(date +%s)}"
DM_KEEPER="${DM_KEEPER:-dm-$KEEPER_TAG}"
ROUND_TIMEOUT_SEC="${ROUND_TIMEOUT_SEC:-30}"
ROUND_KEEPER_TIMEOUT_SEC="${ROUND_KEEPER_TIMEOUT_SEC:-}"
STRICT_MIN_KEEPER_TIMEOUT_SEC="${STRICT_MIN_KEEPER_TIMEOUT_SEC:-30}"
ROUND_RUN_RETRY_COUNT="${ROUND_RUN_RETRY_COUNT:-1}"
ROUND_RUN_ALLOW_MUTATING_RETRY="${ROUND_RUN_ALLOW_MUTATING_RETRY:-0}"
KEEPER_MODELS="${KEEPER_MODELS:-}"
ROUND_LOCAL_FALLBACK="${ROUND_LOCAL_FALLBACK:-1}"
REQUIRE_FULL_PARTY_SUCCESS="${REQUIRE_FULL_PARTY_SUCCESS:-0}"
REQUIRE_AGENT_DRIVEN="${REQUIRE_AGENT_DRIVEN:-0}"
REQUIRE_NO_HEURISTIC="${REQUIRE_NO_HEURISTIC:-0}"
REQUIRE_SESSION_OUTCOME="${REQUIRE_SESSION_OUTCOME:-0}"
OUTCOME_MAX_TURN="${OUTCOME_MAX_TURN:-}"
TRANSCRIPT_PATH="${TRANSCRIPT_PATH:-}"
STRICT_DIALOGUE_MODE_EXPLICIT=0
if [ -n "${STRICT_DIALOGUE_MODE+x}" ]; then
  STRICT_DIALOGUE_MODE_EXPLICIT=1
fi
STRICT_DIALOGUE_MODE="${STRICT_DIALOGUE_MODE:-0}"
REQUIRE_CLAIM_EXPLICIT=0
if [ -n "${REQUIRE_CLAIM+x}" ]; then
  REQUIRE_CLAIM_EXPLICIT=1
fi
REQUIRE_CLAIM="${REQUIRE_CLAIM:-false}"
KEEPER_AUTO_HANDOFF="${KEEPER_AUTO_HANDOFF:-1}"
KEEPER_HANDOFF_THRESHOLD="${KEEPER_HANDOFF_THRESHOLD:-0.82}"
KEEPER_CONTEXT_BUDGET="${KEEPER_CONTEXT_BUDGET:-0.70}"
KEEPER_COMPACTION_PROFILE="${KEEPER_COMPACTION_PROFILE:-balanced}"
KEEPER_COMPACTION_RATIO_GATE="${KEEPER_COMPACTION_RATIO_GATE:-0.72}"
KEEPER_CONTINUITY_COOLDOWN_SEC="${KEEPER_CONTINUITY_COOLDOWN_SEC:-180}"
KEEPER_DRIFT_ENABLED="${KEEPER_DRIFT_ENABLED:-0}"
KEEPER_PRECHECK_ENABLED="${KEEPER_PRECHECK_ENABLED:-1}"
KEEPER_PRECHECK_RETRIES="${KEEPER_PRECHECK_RETRIES:-3}"
KEEPER_PRECHECK_DELAY_SEC="${KEEPER_PRECHECK_DELAY_SEC:-1}"
KEEPER_PRECHECK_TIMEOUT_SEC="${KEEPER_PRECHECK_TIMEOUT_SEC:-45}"
KEEPER_PRECHECK_RECYCLE_ON_FAIL="${KEEPER_PRECHECK_RECYCLE_ON_FAIL:-1}"
STRICT_KEEPER_RECOVERY_ENABLED="${STRICT_KEEPER_RECOVERY_ENABLED:-1}"
STRICT_KEEPER_RECOVERY_MAX_RETRIES="${STRICT_KEEPER_RECOVERY_MAX_RETRIES:-2}"
STRICT_KEEPER_RECOVERY_DELAY_SEC="${STRICT_KEEPER_RECOVERY_DELAY_SEC:-1}"
PLAYER_KEEPER_NAMES=""
CLAIMED_ACTORS=""
CURL_TIMEOUT_SEC="${CURL_TIMEOUT_SEC:-120}"
CURL_RETRY_COUNT="${CURL_RETRY_COUNT:-12}"
CURL_RETRY_DELAY_SEC="${CURL_RETRY_DELAY_SEC:-1}"
ROUND_HTTP_TIMEOUT_SEC="${ROUND_HTTP_TIMEOUT_SEC:-$((ROUND_TIMEOUT_SEC + 180))}"
round_failures=0
rounds_completed=0
timeout_total=0
unavailable_total=0
stall_reason_lines=""
last_progress_reason=""
last_progress_detail=""
last_dm_progress_detail=""
last_dm_non_ok_statuses='[]'
stream_count=0
session_outcome_seen="false"
last_outcome=""
last_outcome_reason=""
transcript_entries=0
local_fallback_applied_total=0
incomplete_party_rounds=0
dm_failed_rounds=0
agent_driven_violations=0
inferred_actions_total=0
no_heuristic_violations=0
strict_rejection_total=0
last_validation_failure_reason=""
last_validation_failure_stage=""
keeper_precheck_failures=0
strict_keeper_recovery_attempts=0
strict_keeper_recovery_successes=0
strict_keeper_recovery_failures=0
OUTCOME_MAX_TURN_EFFECTIVE=""

cleanup_keepers() {
  if [ -n "${room_id:-}" ] && [ -n "${CLAIMED_ACTORS:-}" ]; then
    while IFS='|' read -r actor_id keeper_name; do
      [ -z "$actor_id" ] && continue
      [ -z "$keeper_name" ] && continue
      call_tool 3899 "trpg.actor.release" "$(jq -cn --arg room "$room_id" --arg actor "$actor_id" --arg keeper "$keeper_name" '{room_id:$room,actor_id:$actor,keeper_name:$keeper}')" >/dev/null 2>&1 || true
    done <<< "$CLAIMED_ACTORS"
  fi
  if [ -n "${DM_KEEPER:-}" ]; then
    call_tool 3901 "masc_keeper_down" "$(jq -cn --arg name "$DM_KEEPER" '{name:$name,remove_meta:true,remove_session:true}')" >/dev/null 2>&1 || true
  fi
  if [ -n "${PLAYER_KEEPER_NAMES:-}" ]; then
    while IFS= read -r keeper_name; do
      [ -z "$keeper_name" ] && continue
      call_tool 3902 "masc_keeper_down" "$(jq -cn --arg name "$keeper_name" '{name:$name,remove_meta:true,remove_session:true}')" >/dev/null 2>&1 || true
    done <<< "$PLAYER_KEEPER_NAMES"
  fi
}
trap cleanup_keepers EXIT

call_tool() {
  local id="$1"
  local name="$2"
  local args_json="$3"
  local timeout_sec="${4:-$CURL_TIMEOUT_SEC}"
  local retry_count="${5:-$CURL_RETRY_COUNT}"
  local raw=""
  local sse_data
  local attempt=1
  while [ "$attempt" -le "$retry_count" ]; do
    if raw="$(curl -sS -m "$timeout_sec" -X POST "$MCP_URL" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -d "{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":\"tools/call\",\"params\":{\"name\":\"$name\",\"arguments\":$args_json}}")"; then
      break
    fi
    if [ "$attempt" -lt "$retry_count" ]; then
      sleep "$CURL_RETRY_DELAY_SEC"
    fi
    attempt=$((attempt + 1))
  done
  if [ -z "$raw" ]; then
    printf '{"error":{"message":"curl failed after retries: tool=%s timeout_sec=%s retries=%s"}}' "$name" "$timeout_sec" "$retry_count"
    return 0
  fi
  sse_data="$(printf "%s" "$raw" | sed -n 's/^data: //p' | tail -n1)"
  if [ -n "$sse_data" ]; then
    printf "%s" "$sse_data"
  else
    printf "%s" "$raw"
  fi
}

tool_error_message() {
  local raw="$1"
  printf "%s" "$raw" | jq -r '
    if .error?.message then .error.message
    elif (.result?.isError // false) == true then
      ([.result.content[]? | select(.type == "text") | .text] | join(" "))
    else
      empty
    end
  ' 2>/dev/null | awk 'NF { print; exit }'
}

call_tool_checked() {
  local id="$1"
  local name="$2"
  local args_json="$3"
  local timeout_sec="${4:-$CURL_TIMEOUT_SEC}"
  local retry_count="${5:-$CURL_RETRY_COUNT}"
  local raw
  local err
  raw="$(call_tool "$id" "$name" "$args_json" "$timeout_sec" "$retry_count")"
  if [ -z "$(printf "%s" "$raw" | LC_ALL=C tr -d '[:space:]')" ]; then
    echo "FAIL: $name: empty response from MCP" >&2
    exit 1
  fi
  err="$(tool_error_message "$raw")"
  if [ -n "$err" ]; then
    echo "FAIL: $name: $err" >&2
    printf "%s\n" "$raw" >&2
    exit 1
  fi
  printf "%s" "$raw"
}

payload() {
  jq -c '
    if .result? then
      if .result.structuredContent?.payload? then .result.structuredContent.payload
      elif .result.payload? then .result.payload
      elif (.result.content | type) == "array" then
        ((.result.content[]? | select(.type == "text") | .text) // "{}" | (try fromjson catch {}))
        | if .payload? then .payload else . end
      else {}
      end
    elif .payload? then .payload
    else .
    end
  '
}

list_world_preset_ids() {
  local raw
  raw="$(call_tool 2990 "trpg.preset.list" "{}" "20" "1")"
  printf "%s" "$raw" \
    | payload \
    | jq -r '
      [
        (.world_presets // []),
        (.presets // []),
        (.world // []),
        (.items // [])
      ]
      | flatten
      | .[]?
      | (.id // .preset_id // .name // empty)
    ' 2>/dev/null \
    | awk 'NF'
}

resolve_world_preset_id() {
  if [ -n "$WORLD_PRESET_ID" ]; then
    return 0
  fi
  if [ "$RUN_ROUND" != "1" ]; then
    return 0
  fi
  local preset_ids=""
  local candidate=""
  preset_ids="$(list_world_preset_ids || true)"
  for candidate in grimland-quickshow grimland-chronicle emberfall-siege; do
    if printf "%s\n" "$preset_ids" | grep -Fxq "$candidate"; then
      WORLD_PRESET_ID="$candidate"
      break
    fi
  done
  if [ -z "$WORLD_PRESET_ID" ]; then
    WORLD_PRESET_ID="$(printf "%s\n" "$preset_ids" | awk 'NF {print; exit}')"
  fi
  if [ -z "$WORLD_PRESET_ID" ]; then
    WORLD_PRESET_ID="grimland-chronicle"
  fi
}

build_models_json() {
  jq -cn --arg csv "$KEEPER_MODELS" '
    $csv
    | split(",")
    | map(gsub("^\\s+|\\s+$";""))
    | map(select(length > 0))
  '
}

bool_to_json() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) printf "true" ;;
    *) printf "false" ;;
  esac
}

extract_keeper_text_response() {
  local raw="$1"
  local text=""
  local nested=""
  text="$(printf "%s" "$raw" | jq -r '
    if .result?.structuredContent?.payload?.reply? then .result.structuredContent.payload.reply
    elif .result?.structuredContent?.payload?.response? then .result.structuredContent.payload.response
    elif .result?.structuredContent?.reply? then .result.structuredContent.reply
    elif .result?.structuredContent?.response? then .result.structuredContent.response
    elif .result?.payload?.reply? then .result.payload.reply
    elif .result?.payload?.response? then .result.payload.response
    elif (.result?.content | type) == "array" then
      [.result.content[]? | select(.type == "text") | .text] | join("\n")
    else ""
    end
  ' 2>/dev/null || printf "")"
  if [ -z "$(printf "%s" "$text" | tr -d '[:space:]')" ]; then
    printf ""
    return 0
  fi
  nested="$(printf "%s" "$text" | jq -r '
    .reply
    // .payload.reply
    // .response
    // .payload.response
    // (if (.result?.content | type) == "array" then
          [.result.content[]? | select(.type == "text") | .text] | join("\n")
        else "" end)
  ' 2>/dev/null || printf "")"
  if [ -n "$(printf "%s" "$nested" | tr -d '[:space:]')" ]; then
    printf "%s" "$nested"
  else
    printf "%s" "$text"
  fi
}

keeper_precheck_once() {
  local keeper_name="$1"
  local role="$2"
  local timeout_sec="$3"
  local raw
  local err
  local sample_type="attack"
  local sample_description="화염병을 던져 고블린 궁수의 시야를 끊고 측면 돌파로를 연다"
  if [ "$role" = "dm" ]; then
    sample_type="set_flag"
    sample_description="붕괴 직전의 석문에 봉인각인을 새겨 추격대를 지연시킨다"
  fi
  local response_text=""
  local snippet=""
  local sa_json=""
  local sa_type=""
  local type_allowed=0
  local has_structured_action=0
  local precheck_turn_instruction="이 턴은 형식 검증용입니다. 반드시 아래 규칙을 지키세요.
- 정확히 2줄만 출력
- 1줄: 한국어 서사 1문장
- 2줄: structured_action: {\"type\":\"$sample_type\",\"description\":\"$sample_description\"}
- SKILL/SKILL_REASON/[STATE] 금지"
  local precheck_prompt="준비 상태 점검입니다. 아래 형식을 정확히 지키세요.
한 줄 서사
structured_action: {\"type\":\"$sample_type\",\"description\":\"$sample_description\"}
금지: 메타문구, SKILL/STATE, 'trpg-roleplay 스킬을 활용해 행동을 이어갑니다.'"
  raw="$(call_tool 3330 "masc_keeper_msg" "$(jq -cn --arg name "$keeper_name" --arg message "$precheck_prompt" --arg turn_instructions "$precheck_turn_instruction" --argjson timeout "$timeout_sec" '{name:$name,message:$message,turn_instructions:$turn_instructions,timeout_sec:$timeout,no_skill_route:true,no_state_block:true,require_existing:true}')" "$((timeout_sec + 10))" "1")"
  err="$(tool_error_message "$raw")"
  if [ -n "$err" ]; then
    echo "[precheck] keeper=$keeper_name role=$role status=fail error=$err"
    return 1
  fi
  response_text="$(extract_keeper_text_response "$raw")"
  snippet="$(printf "%s" "$response_text" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | cut -c1-160)"
  if [ -z "$(printf "%s" "$response_text" | tr -d '[:space:]')" ]; then
    echo "[precheck] keeper=$keeper_name role=$role status=fail reason=empty_reply sample=${snippet:-<empty>}"
    return 1
  fi
  if printf "%s" "$response_text" | grep -Eq 'structured_action[[:space:]]*:[[:space:]]*\{'; then
    has_structured_action=1
  else
    if [ "$STRICT_DIALOGUE_MODE" = "1" ]; then
      echo "[precheck] keeper=$keeper_name role=$role status=fail reason=missing_structured_action sample=${snippet:-<empty>}"
      return 1
    else
      echo "[precheck] keeper=$keeper_name role=$role status=warn reason=missing_structured_action sample=${snippet:-<empty>}"
    fi
  fi
  if [ "$has_structured_action" -eq 1 ]; then
    sa_json="$(printf "%s" "$response_text" | sed -nE 's/.*structured_action[[:space:]]*:[[:space:]]*(\{.*\}).*/\1/p' | head -n1)"
    sa_type="$(printf "%s" "$sa_json" | jq -r '.type // empty' 2>/dev/null || true)"
    if [ -z "$sa_type" ]; then
      echo "[precheck] keeper=$keeper_name role=$role status=fail reason=invalid_structured_action_json sample=${snippet:-<empty>}"
      return 1
    fi
    if [ "$role" = "dm" ]; then
      case "$sa_type" in
        set_flag|world_event|quest_update|transition|talk) type_allowed=1 ;;
      esac
    else
      case "$sa_type" in
        attack|move|skill|defend|talk|item|cast) type_allowed=1 ;;
      esac
    fi
    if [ "$type_allowed" -ne 1 ]; then
      echo "[precheck] keeper=$keeper_name role=$role status=fail reason=invalid_action_type:$sa_type sample=${snippet:-<empty>}"
      return 1
    fi
  fi
  if printf "%s" "$response_text" | grep -Eq 'SKILL:|SKILL_REASON:|\[STATE\]|state_snapshot_json|내 기록 기준으로는|직전에 이런 질문을 했어'; then
    echo "[precheck] keeper=$keeper_name role=$role status=fail reason=meta_marker_detected sample=${snippet:-<empty>}"
    return 1
  fi
  if printf "%s" "$response_text" | grep -Eq 'trpg-roleplay 스킬을 활용해 행동을 이어갑니다\.'; then
    echo "[precheck] keeper=$keeper_name role=$role status=fail reason=placeholder_phrase sample=${snippet:-<empty>}"
    return 1
  fi
  echo "[precheck] keeper=$keeper_name role=$role status=ok sample=${snippet:-<empty>}"
  return 0
}

keeper_precheck_or_fail() {
  local keeper_name="$1"
  local role="$2"
  local attempt=1
  local max_attempts="$KEEPER_PRECHECK_RETRIES"
  while [ "$attempt" -le "$max_attempts" ]; do
    if keeper_precheck_once "$keeper_name" "$role" "$KEEPER_PRECHECK_TIMEOUT_SEC"; then
      append_transcript_entry "keeper_precheck" "$(jq -cn --arg keeper "$keeper_name" --arg role "$role" --argjson attempt "$attempt" '{keeper:$keeper,role:$role,attempt:$attempt,status:"ok"}')"
      return 0
    fi
    if [ "$(bool_to_json "$KEEPER_PRECHECK_RECYCLE_ON_FAIL")" = "true" ]; then
      if recycle_keeper_for_precheck "$role" "$keeper_name"; then
        append_transcript_entry "keeper_precheck_recycle" "$(jq -cn --arg keeper "$keeper_name" --arg role "$role" --argjson attempt "$attempt" '{keeper:$keeper,role:$role,attempt:$attempt,status:"ok"}')"
      else
        append_transcript_entry "keeper_precheck_recycle" "$(jq -cn --arg keeper "$keeper_name" --arg role "$role" --argjson attempt "$attempt" '{keeper:$keeper,role:$role,attempt:$attempt,status:"fail"}')"
      fi
    fi
    if [ "$attempt" -lt "$max_attempts" ]; then
      sleep "$KEEPER_PRECHECK_DELAY_SEC"
    fi
    attempt=$((attempt + 1))
  done
  keeper_precheck_failures=$((keeper_precheck_failures + 1))
  last_progress_reason="keeper_precheck_failed"
  last_progress_detail="${role}:${keeper_name}"
  stall_reason_lines="${stall_reason_lines}${stall_reason_lines:+$'\n'}keeper_precheck_failed"
  append_transcript_entry "keeper_precheck" "$(jq -cn --arg keeper "$keeper_name" --arg role "$role" --argjson retries "$max_attempts" '{keeper:$keeper,role:$role,retries:$retries,status:"fail"}')"
  echo "FAIL: keeper precheck failed role=$role keeper=$keeper_name retries=$max_attempts" >&2
  echo "[grimland-summary] $(emit_grimland_summary "fail")"
  exit 1
}

build_dm_instruction() {
  if [ "$STRICT_DIALOGUE_MODE" = "1" ]; then
    cat <<'EOF'
모든 응답은 한국어로 작성하세요. 당신은 DM으로서 서사를 전개하고 턴 정체를 피해야 합니다.
아래 문구/형식은 금지합니다:
- "trpg-roleplay 스킬을 활용해 행동을 이어갑니다."
- 의미 없는 일반론/메타 설명
- SKILL:, SKILL_REASON:, [STATE], state_snapshot_json
반드시 현재 턴 상황을 반영한 구체적 서사(대상/위협/의도 포함)를 제시하고 structured_action을 유효하게 포함하세요.
EOF
  else
    cat <<'EOF'
모든 응답은 한국어로 작성하세요. 당신은 DM으로서 서사를 전개하고 턴 정체를 피해야 합니다.
EOF
  fi
}

build_player_instruction() {
  if [ "$STRICT_DIALOGUE_MODE" = "1" ]; then
    cat <<'EOF'
모든 응답은 한국어로 작성하세요. 당신은 보조자가 아니라 해당 액터를 직접 플레이하는 주체입니다.
아래 문구/형식은 금지합니다:
- "trpg-roleplay 스킬을 활용해 행동을 이어갑니다."
- 추상적/반복적 한 줄 메타 문장
- SKILL:, SKILL_REASON:, [STATE], state_snapshot_json
반드시 현재 전황/목표를 반영한 구체 행동(누구에게 무엇을 왜 하는지)으로 답하고 structured_action을 유효하게 포함하세요.
EOF
  else
    cat <<'EOF'
모든 응답은 한국어로 작성하세요. 당신은 보조자가 아니라 해당 액터를 직접 플레이하는 주체입니다.
EOF
  fi
}

collect_strict_recovery_targets() {
  local round_payload="$1"
  printf "%s" "$round_payload" | jq -r '
    [
      .statuses[]?
      | select(
          (
            (.status // "") == "schema_invalid"
            or (.status // "") == "rule_invalid"
            or (.status // "") == "duplicate_reply_warning"
            or (.status // "") == "missing_structured_action"
            or (.status // "") == "unavailable"
            or (.status // "") == "timeout"
          )
          and ((.keeper // "") != "")
        )
      | "\((.role // ""))|\((.actor_id // ""))|\((.keeper // ""))"
    ]
    | unique
    | .[]
  ' 2>/dev/null || true
}

restart_dm_keeper() {
  local keeper_name="$1"
  local raw
  local err
  raw="$(call_tool 3970 "masc_keeper_down" "$(jq -cn --arg name "$keeper_name" '{name:$name,remove_meta:true,remove_session:true}')")"
  err="$(tool_error_message "$raw")"
  if [ -n "$err" ]; then
    echo "[recovery] warn: keeper_down failed keeper=$keeper_name error=$err" >&2
  fi
  raw="$(call_tool 3971 "masc_keeper_up" "$(jq -cn \
    --arg name "$keeper_name" \
    --arg room "$room_id" \
    --arg instructions "$DM_KEEPER_INSTRUCTIONS" \
    --argjson models "$KEEPER_MODELS_JSON" \
    --argjson auto_handoff "$KEEPER_AUTO_HANDOFF_JSON" \
    --argjson handoff_threshold "$KEEPER_HANDOFF_THRESHOLD" \
    --argjson context_budget "$KEEPER_CONTEXT_BUDGET" \
    --arg compaction_profile "$KEEPER_COMPACTION_PROFILE" \
    --argjson compaction_ratio_gate "$KEEPER_COMPACTION_RATIO_GATE" \
    --argjson continuity_compaction_cooldown_sec "$KEEPER_CONTINUITY_COOLDOWN_SEC" \
    --argjson drift_enabled "$KEEPER_DRIFT_ENABLED_JSON" \
    '{name:$name,goal:("TRPG room " + $room + " DM keeper"),instructions:$instructions,models:$models,proactive_enabled:false,presence_keepalive:true,auto_handoff:$auto_handoff,handoff_threshold:$handoff_threshold,context_budget:$context_budget,compaction_profile:$compaction_profile,compaction_ratio_gate:$compaction_ratio_gate,continuity_compaction_cooldown_sec:$continuity_compaction_cooldown_sec,drift_enabled:$drift_enabled}')")"
  err="$(tool_error_message "$raw")"
  if [ -n "$err" ]; then
    echo "[recovery] fail: keeper_up failed keeper=$keeper_name role=dm error=$err" >&2
    return 1
  fi
  return 0
}

extract_actor_owner_from_error() {
  local err_msg="$1"
  printf "%s" "$err_msg" \
    | sed -nE 's/.*owner=([^", }]+).*/\1/p' \
    | head -n1
}

release_actor_with_owner() {
  local actor_id="$1"
  local owner="$2"
  local raw
  local err
  [ -z "$actor_id" ] && return 1
  [ -z "$owner" ] && return 1
  raw="$(call_tool 3972 "trpg.actor.release" "$(jq -cn --arg room "$room_id" --arg actor "$actor_id" --arg keeper "$owner" '{room_id:$room,actor_id:$actor,keeper_name:$keeper}')")"
  err="$(tool_error_message "$raw")"
  if [ -n "$err" ]; then
    echo "[recovery] warn: actor.release(owner) failed actor=$actor_id owner=$owner error=$err" >&2
    return 1
  fi
  echo "[recovery] info: actor.release(owner) succeeded actor=$actor_id owner=$owner" >&2
  return 0
}

restart_player_keeper() {
  local actor_id="$1"
  local keeper_name="$2"
  local raw
  local err
  local owner
  if [ -z "$actor_id" ]; then
    echo "[recovery] fail: missing actor_id for keeper=$keeper_name" >&2
    return 1
  fi
  raw="$(call_tool 3972 "trpg.actor.release" "$(jq -cn --arg room "$room_id" --arg actor "$actor_id" --arg keeper "$keeper_name" '{room_id:$room,actor_id:$actor,keeper_name:$keeper}')")"
  err="$(tool_error_message "$raw")"
  if [ -n "$err" ]; then
    echo "[recovery] warn: actor.release failed actor=$actor_id keeper=$keeper_name error=$err" >&2
    owner="$(extract_actor_owner_from_error "$err")"
    if [ -n "$owner" ] && [ "$owner" != "$keeper_name" ]; then
      release_actor_with_owner "$actor_id" "$owner" || true
    fi
  fi
  raw="$(call_tool 3973 "masc_keeper_down" "$(jq -cn --arg name "$keeper_name" '{name:$name,remove_meta:true,remove_session:true}')")"
  err="$(tool_error_message "$raw")"
  if [ -n "$err" ]; then
    echo "[recovery] warn: keeper_down failed keeper=$keeper_name actor=$actor_id error=$err" >&2
  fi
  raw="$(call_tool 3974 "masc_keeper_up" "$(jq -cn \
    --arg name "$keeper_name" \
    --arg room "$room_id" \
    --arg actor "$actor_id" \
    --arg instructions "$PLAYER_KEEPER_INSTRUCTIONS" \
    --argjson models "$KEEPER_MODELS_JSON" \
    --argjson auto_handoff "$KEEPER_AUTO_HANDOFF_JSON" \
    --argjson handoff_threshold "$KEEPER_HANDOFF_THRESHOLD" \
    --argjson context_budget "$KEEPER_CONTEXT_BUDGET" \
    --arg compaction_profile "$KEEPER_COMPACTION_PROFILE" \
    --argjson compaction_ratio_gate "$KEEPER_COMPACTION_RATIO_GATE" \
    --argjson continuity_compaction_cooldown_sec "$KEEPER_CONTINUITY_COOLDOWN_SEC" \
    --argjson drift_enabled "$KEEPER_DRIFT_ENABLED_JSON" \
    '{name:$name,goal:("TRPG room " + $room + "에서 " + $actor + " actor를 플레이하세요."),instructions:$instructions,models:$models,proactive_enabled:false,presence_keepalive:true,auto_handoff:$auto_handoff,handoff_threshold:$handoff_threshold,context_budget:$context_budget,compaction_profile:$compaction_profile,compaction_ratio_gate:$compaction_ratio_gate,continuity_compaction_cooldown_sec:$continuity_compaction_cooldown_sec,drift_enabled:$drift_enabled}')")"
  err="$(tool_error_message "$raw")"
  if [ -n "$err" ]; then
    echo "[recovery] fail: keeper_up failed keeper=$keeper_name actor=$actor_id error=$err" >&2
    return 1
  fi
  raw="$(call_tool 3975 "trpg.actor.claim" "$(jq -cn --arg room "$room_id" --arg actor "$actor_id" --arg keeper "$keeper_name" '{room_id:$room,actor_id:$actor,keeper_name:$keeper}')")"
  err="$(tool_error_message "$raw")"
  if [ -n "$err" ]; then
    owner="$(extract_actor_owner_from_error "$err")"
    if [ -n "$owner" ] && [ "$owner" != "$keeper_name" ]; then
      echo "[recovery] warn: actor.claim owner mismatch actor=$actor_id keeper=$keeper_name owner=$owner; retrying reclaim" >&2
      if release_actor_with_owner "$actor_id" "$owner"; then
        raw="$(call_tool 3975 "trpg.actor.claim" "$(jq -cn --arg room "$room_id" --arg actor "$actor_id" --arg keeper "$keeper_name" '{room_id:$room,actor_id:$actor,keeper_name:$keeper}')")"
        err="$(tool_error_message "$raw")"
        if [ -z "$err" ]; then
          return 0
        fi
      fi
    fi
    if printf "%s" "$err" | grep -Eqi 'join gate failed|insufficient_contribution'; then
      echo "[recovery] warn: actor.claim soft-failed actor=$actor_id keeper=$keeper_name error=$err" >&2
      return 0
    fi
    if printf "%s" "$err" | grep -Eqi 'actor is not alive'; then
      echo "[recovery] warn: actor.claim skipped-dead actor=$actor_id keeper=$keeper_name error=$err" >&2
      return 0
    fi
    echo "[recovery] fail: actor.claim failed actor=$actor_id keeper=$keeper_name error=$err" >&2
    return 1
  fi
  return 0
}

recycle_keeper_for_precheck() {
  local role="$1"
  local keeper_name="$2"
  local actor_id=""
  if [ "$role" = "dm" ]; then
    restart_dm_keeper "$keeper_name"
    return $?
  fi
  if [[ "$role" == player:* ]]; then
    actor_id="${role#player:}"
    if [ -z "$actor_id" ]; then
      echo "[precheck] warn: cannot recycle keeper=$keeper_name role=$role (missing actor_id)" >&2
      return 1
    fi
    restart_player_keeper "$actor_id" "$keeper_name"
    return $?
  fi
  echo "[precheck] warn: unknown role format for recycle role=$role keeper=$keeper_name" >&2
  return 1
}

recover_keepers_from_noncompliance() {
  local round_payload="$1"
  local round_no="$2"
  local recovery_attempt="$3"
  local targets
  local failed=0
  local recovered=0
  local actor_id
  local role
  local keeper_name
  targets="$(collect_strict_recovery_targets "$round_payload")"
  if [ -z "$(printf "%s" "$targets" | awk 'NF {print; exit}')" ]; then
    echo "[recovery] round=$round_no attempt=$recovery_attempt no strict target keeper found; fallback to full keeper recycle" >&2
    targets="dm|dm|$DM_KEEPER"
    while IFS='|' read -r actor_id keeper_name; do
      [ -z "$actor_id" ] && continue
      [ -z "$keeper_name" ] && continue
      targets="${targets}"$'\n'"player|${actor_id}|${keeper_name}"
    done <<< "$CLAIMED_ACTORS"
  fi
  echo "[recovery] round=$round_no attempt=$recovery_attempt restarting keepers for strict structured_action violations"
  append_transcript_entry "keeper_recovery_start" "$(jq -cn --argjson round "$round_no" --argjson attempt "$recovery_attempt" --arg targets "$targets" '{round:$round,attempt:$attempt,targets:($targets|split("\n")|map(select(length>0)))}')"
  while IFS='|' read -r role actor_id keeper_name; do
    [ -z "$keeper_name" ] && continue
    if [ "$role" = "dm" ]; then
      if restart_dm_keeper "$keeper_name"; then
        recovered=$((recovered + 1))
      else
        failed=$((failed + 1))
      fi
    else
      if restart_player_keeper "$actor_id" "$keeper_name"; then
        recovered=$((recovered + 1))
      else
        failed=$((failed + 1))
      fi
    fi
  done <<< "$targets"
  append_transcript_entry "keeper_recovery_result" "$(jq -cn --argjson round "$round_no" --argjson attempt "$recovery_attempt" --argjson recovered "$recovered" --argjson failed "$failed" '{round:$round,attempt:$attempt,recovered:$recovered,failed:$failed}')"
  if [ "$failed" -gt 0 ] || [ "$recovered" -eq 0 ]; then
    return 1
  fi
  return 0
}

top_reason_line() {
  local raw="${1:-}"
  printf "%s\n" "$raw" \
    | awk 'NF' \
    | sort \
    | uniq -c \
    | sort -nr \
    | head -n1 \
    | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//'
}

emit_grimland_summary() {
  local outcome="${1:-unknown}"
  local requested_rounds=0
  local round_keeper_timeout_json='null'
  local run_round_json
  local local_fallback_json
  local require_full_party_json
  local require_agent_driven_json
  local require_no_heuristic_json
  local require_claim_json
  local session_outcome_json
  local agent_driven_pass_json
  local no_heuristic_pass_json
  local keeper_precheck_enabled_json
  local strict_keeper_recovery_enabled_json
  local stall_reason_top
  run_round_json="$(bool_to_json "$RUN_ROUND")"
  local_fallback_json="$(bool_to_json "$ROUND_LOCAL_FALLBACK")"
  require_full_party_json="$(bool_to_json "$REQUIRE_FULL_PARTY_SUCCESS")"
  require_agent_driven_json="$(bool_to_json "$REQUIRE_AGENT_DRIVEN")"
  require_no_heuristic_json="$(bool_to_json "$REQUIRE_NO_HEURISTIC")"
  require_claim_json="$(bool_to_json "$REQUIRE_CLAIM")"
  keeper_precheck_enabled_json="$(bool_to_json "$KEEPER_PRECHECK_ENABLED")"
  strict_keeper_recovery_enabled_json="$(bool_to_json "$STRICT_KEEPER_RECOVERY_ENABLED")"
  session_outcome_json="$(bool_to_json "$session_outcome_seen")"
  if [ "$agent_driven_violations" -eq 0 ]; then
    agent_driven_pass_json="true"
  else
    agent_driven_pass_json="false"
  fi
  if [ "$no_heuristic_violations" -eq 0 ] && [ "$inferred_actions_total" -eq 0 ]; then
    no_heuristic_pass_json="true"
  else
    no_heuristic_pass_json="false"
  fi
  stall_reason_top="$(top_reason_line "$stall_reason_lines")"
  if [ -n "$(printf "%s" "$ROUND_KEEPER_TIMEOUT_SEC" | tr -d '[:space:]')" ]; then
    round_keeper_timeout_json="$(jq -cn --argjson sec "$ROUND_KEEPER_TIMEOUT_SEC" '$sec')"
  fi
  if [ "$RUN_ROUND" = "1" ]; then
    requested_rounds="$ROUNDS"
  fi
  jq -cn \
    --arg result "$outcome" \
    --arg room_id "${room_id:-}" \
    --arg session_id "$SESSION_ID" \
    --arg world_preset "${world_used:-}" \
    --arg dm_preset "${dm_used:-}" \
    --arg dm_keeper "$DM_KEEPER" \
    --arg last_progress_reason "$last_progress_reason" \
    --arg last_progress_detail "$last_progress_detail" \
    --arg last_dm_progress_detail "$last_dm_progress_detail" \
    --argjson last_dm_non_ok_statuses "$last_dm_non_ok_statuses" \
    --arg last_validation_failure_reason "$last_validation_failure_reason" \
    --arg last_validation_failure_stage "$last_validation_failure_stage" \
    --arg stall_reason_top "$stall_reason_top" \
    --arg last_outcome "$last_outcome" \
    --arg last_outcome_reason "$last_outcome_reason" \
    --arg transcript_path "$TRANSCRIPT_PATH" \
    --argjson run_round "$run_round_json" \
    --argjson local_fallback "$local_fallback_json" \
    --argjson require_full_party_success "$require_full_party_json" \
    --argjson require_agent_driven "$require_agent_driven_json" \
    --argjson require_no_heuristic "$require_no_heuristic_json" \
    --argjson require_claim "$require_claim_json" \
    --argjson rounds_requested "$requested_rounds" \
    --argjson round_keeper_timeout_sec "$round_keeper_timeout_json" \
    --argjson rounds_completed "$rounds_completed" \
    --argjson failed_rounds "$round_failures" \
    --argjson timeout_total "$timeout_total" \
    --argjson unavailable_total "$unavailable_total" \
    --argjson stream_event_count "$stream_count" \
    --argjson session_outcome_seen "$session_outcome_json" \
    --argjson transcript_entries "$transcript_entries" \
    --argjson local_fallback_applied_total "$local_fallback_applied_total" \
    --argjson incomplete_party_rounds "$incomplete_party_rounds" \
    --argjson dm_failed_rounds "$dm_failed_rounds" \
    --argjson agent_driven_violations "$agent_driven_violations" \
    --argjson agent_driven_pass "$agent_driven_pass_json" \
    --argjson inferred_actions_total "$inferred_actions_total" \
    --argjson no_heuristic_violations "$no_heuristic_violations" \
    --argjson no_heuristic_pass "$no_heuristic_pass_json" \
    --argjson strict_rejection_total "$strict_rejection_total" \
    --argjson keeper_precheck_enabled "$keeper_precheck_enabled_json" \
    --argjson strict_keeper_recovery_enabled "$strict_keeper_recovery_enabled_json" \
    --argjson keeper_precheck_retries "$KEEPER_PRECHECK_RETRIES" \
    --argjson keeper_precheck_failures "$keeper_precheck_failures" \
    --argjson strict_keeper_recovery_max_retries "$STRICT_KEEPER_RECOVERY_MAX_RETRIES" \
    --argjson strict_keeper_recovery_attempts "$strict_keeper_recovery_attempts" \
    --argjson strict_keeper_recovery_successes "$strict_keeper_recovery_successes" \
    --argjson strict_keeper_recovery_failures "$strict_keeper_recovery_failures" \
    '{
      result:$result,
      room_id:$room_id,
      session_id:$session_id,
      world_preset:$world_preset,
      dm_preset:$dm_preset,
      dm_keeper:$dm_keeper,
      run_round:$run_round,
      local_fallback:$local_fallback,
      require_full_party_success:$require_full_party_success,
      require_agent_driven:$require_agent_driven,
      require_no_heuristic:$require_no_heuristic,
      require_claim:$require_claim,
      keeper_precheck_enabled:$keeper_precheck_enabled,
      strict_keeper_recovery_enabled:$strict_keeper_recovery_enabled,
      keeper_precheck_retries:$keeper_precheck_retries,
      rounds_requested:$rounds_requested,
      round_keeper_timeout_sec:$round_keeper_timeout_sec,
      rounds_completed:$rounds_completed,
      failed_rounds:$failed_rounds,
      timeout_total:$timeout_total,
      unavailable_total:$unavailable_total,
      last_progress_reason:($last_progress_reason | if . == "" then null else . end),
      last_progress_detail:($last_progress_detail | if . == "" then null else . end),
      dm_progress_detail:($last_dm_progress_detail | if . == "" then null else . end),
      dm_non_ok_statuses:$last_dm_non_ok_statuses,
      last_validation_failure_reason:($last_validation_failure_reason | if . == "" then null else . end),
      last_validation_failure_stage:($last_validation_failure_stage | if . == "" then null else . end),
      last_outcome:($last_outcome | if . == "" then null else . end),
      last_outcome_reason:($last_outcome_reason | if . == "" then null else . end),
      transcript_path:($transcript_path | if . == "" then null else . end),
      transcript_entries:$transcript_entries,
      local_fallback_applied_total:$local_fallback_applied_total,
      incomplete_party_rounds:$incomplete_party_rounds,
      dm_failed_rounds:$dm_failed_rounds,
      agent_driven_violations:$agent_driven_violations,
      agent_driven_pass:$agent_driven_pass,
      inferred_actions_total:$inferred_actions_total,
      no_heuristic_violations:$no_heuristic_violations,
      no_heuristic_pass:$no_heuristic_pass,
      strict_rejection_total:$strict_rejection_total,
      keeper_precheck_failures:$keeper_precheck_failures,
      strict_keeper_recovery_max_retries:$strict_keeper_recovery_max_retries,
      strict_keeper_recovery_attempts:$strict_keeper_recovery_attempts,
      strict_keeper_recovery_successes:$strict_keeper_recovery_successes,
      strict_keeper_recovery_failures:$strict_keeper_recovery_failures,
      stall_reason_top:($stall_reason_top | if . == "" then null else . end),
      stream_event_count:$stream_event_count,
      session_outcome_seen:$session_outcome_seen
    }'
}

append_transcript_entry() {
  local kind="$1"
  local data_json="$2"
  if [ -z "$TRANSCRIPT_PATH" ]; then
    return 0
  fi
  jq -cn \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg kind "$kind" \
    --argjson data "$data_json" \
    '{ts:$ts,kind:$kind,data:$data}' >> "$TRANSCRIPT_PATH"
  transcript_entries=$((transcript_entries + 1))
}

init_transcript() {
  if [ -z "$TRANSCRIPT_PATH" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$TRANSCRIPT_PATH")"
  : > "$TRANSCRIPT_PATH"
  append_transcript_entry "run_start" "$(jq -cn --arg session_id "$SESSION_ID" --arg run_round "$RUN_ROUND" --arg rounds "$ROUNDS" '{session_id:$session_id,run_round:$run_round,rounds:($rounds|tonumber)}')"
}

echo "[bootstrap] trpg.pool.generate"
init_transcript
if [ "$POOL_SIZE" -lt "$PARTY_SIZE" ]; then
  POOL_SIZE="$PARTY_SIZE"
fi
echo "[bootstrap] strict_dialogue_mode=$STRICT_DIALOGUE_MODE"
KEEPER_MODELS_JSON="$(build_models_json)"
KEEPER_AUTO_HANDOFF_JSON="$(bool_to_json "$KEEPER_AUTO_HANDOFF")"
KEEPER_DRIFT_ENABLED_JSON="$(bool_to_json "$KEEPER_DRIFT_ENABLED")"
if [ "$REQUIRE_AGENT_DRIVEN" = "1" ] && [ "$STRICT_DIALOGUE_MODE_EXPLICIT" -ne 1 ] && [ "$STRICT_DIALOGUE_MODE" != "1" ]; then
  STRICT_DIALOGUE_MODE="1"
  echo "[bootstrap] auto-enable strict_dialogue_mode=1 (REQUIRE_AGENT_DRIVEN=1)"
fi
if [ "$REQUIRE_AGENT_DRIVEN" = "1" ] && [ "$REQUIRE_CLAIM_EXPLICIT" -ne 1 ] && [ "$(bool_to_json "$REQUIRE_CLAIM")" != "true" ]; then
  REQUIRE_CLAIM="true"
  echo "[bootstrap] auto-enable require_claim=true (REQUIRE_AGENT_DRIVEN=1)"
fi
round_keeper_timeout_trimmed="$(printf "%s" "$ROUND_KEEPER_TIMEOUT_SEC" | tr -d '[:space:]')"
if [ "$REQUIRE_AGENT_DRIVEN" = "1" ]; then
  if ! awk -v value="$STRICT_MIN_KEEPER_TIMEOUT_SEC" 'BEGIN { exit !(value+0==value && value>0) }'; then
    echo "FAIL: STRICT_MIN_KEEPER_TIMEOUT_SEC must be a positive number" >&2
    exit 1
  fi
  strict_min_keeper_timeout="$STRICT_MIN_KEEPER_TIMEOUT_SEC"
  if awk -v min="$strict_min_keeper_timeout" -v round="$ROUND_TIMEOUT_SEC" 'BEGIN { exit !(min > round) }'; then
    strict_min_keeper_timeout="$ROUND_TIMEOUT_SEC"
  fi
  if [ -z "$round_keeper_timeout_trimmed" ]; then
    ROUND_KEEPER_TIMEOUT_SEC="$strict_min_keeper_timeout"
    round_keeper_timeout_trimmed="$ROUND_KEEPER_TIMEOUT_SEC"
    echo "[bootstrap] auto-enable round_keeper_timeout_sec=$ROUND_KEEPER_TIMEOUT_SEC (REQUIRE_AGENT_DRIVEN=1)"
  elif awk -v value="$ROUND_KEEPER_TIMEOUT_SEC" 'BEGIN { exit !(value+0==value && value>0) }'; then
    if awk -v keeper="$ROUND_KEEPER_TIMEOUT_SEC" -v min="$strict_min_keeper_timeout" 'BEGIN { exit !(keeper < min) }'; then
      ROUND_KEEPER_TIMEOUT_SEC="$strict_min_keeper_timeout"
      round_keeper_timeout_trimmed="$ROUND_KEEPER_TIMEOUT_SEC"
      echo "[bootstrap] auto-bump round_keeper_timeout_sec=$ROUND_KEEPER_TIMEOUT_SEC (REQUIRE_AGENT_DRIVEN=1 strict-min)"
    fi
  fi
fi
if [ -n "$round_keeper_timeout_trimmed" ]; then
  echo "[bootstrap] round_keeper_timeout_sec=$ROUND_KEEPER_TIMEOUT_SEC"
fi
REQUIRE_CLAIM_JSON="$(bool_to_json "$REQUIRE_CLAIM")"
if [ "$(printf "%s" "$KEEPER_MODELS_JSON" | jq 'length')" -eq 0 ]; then
  echo "FAIL: KEEPER_MODELS is required (예: KEEPER_MODELS='gemini:gemini-2.5-flash')" >&2
  exit 1
fi
if [ "$REQUIRE_AGENT_DRIVEN" = "1" ] && [ "$ROUND_LOCAL_FALLBACK" = "1" ]; then
  echo "FAIL: REQUIRE_AGENT_DRIVEN=1 requires ROUND_LOCAL_FALLBACK=0" >&2
  exit 1
fi
if [ -n "$(printf "%s" "$ROUND_KEEPER_TIMEOUT_SEC" | tr -d '[:space:]')" ]; then
  if ! awk -v value="$ROUND_KEEPER_TIMEOUT_SEC" 'BEGIN { exit !(value+0==value && value>0) }'; then
    echo "FAIL: ROUND_KEEPER_TIMEOUT_SEC must be a positive number" >&2
    exit 1
  fi
  if ! awk -v keeper="$ROUND_KEEPER_TIMEOUT_SEC" -v round="$ROUND_TIMEOUT_SEC" 'BEGIN { exit !(keeper <= round) }'; then
    echo "FAIL: ROUND_KEEPER_TIMEOUT_SEC must be <= ROUND_TIMEOUT_SEC" >&2
    exit 1
  fi
fi
if ! [[ "$ROUNDS" =~ ^[0-9]+$ ]] || [ "$ROUNDS" -lt 1 ]; then
  echo "FAIL: ROUNDS must be a positive integer" >&2
  exit 1
fi
OUTCOME_MAX_TURN_EFFECTIVE="$(printf "%s" "$OUTCOME_MAX_TURN" | tr -d '[:space:]')"
if [ -z "$OUTCOME_MAX_TURN_EFFECTIVE" ] && [ "$RUN_ROUND" = "1" ] && [ "$REQUIRE_SESSION_OUTCOME" = "1" ]; then
  OUTCOME_MAX_TURN_EFFECTIVE="$((ROUNDS + 1))"
fi
if [ -n "$OUTCOME_MAX_TURN_EFFECTIVE" ]; then
  if ! [[ "$OUTCOME_MAX_TURN_EFFECTIVE" =~ ^[0-9]+$ ]] || [ "$OUTCOME_MAX_TURN_EFFECTIVE" -lt 1 ]; then
    echo "FAIL: OUTCOME_MAX_TURN must be a positive integer" >&2
    exit 1
  fi
  echo "[bootstrap] outcome_max_turn=$OUTCOME_MAX_TURN_EFFECTIVE"
fi
if [ "$KEEPER_PRECHECK_ENABLED" = "1" ]; then
  if ! [[ "$KEEPER_PRECHECK_RETRIES" =~ ^[0-9]+$ ]] || [ "$KEEPER_PRECHECK_RETRIES" -lt 1 ]; then
    echo "FAIL: KEEPER_PRECHECK_RETRIES must be a positive integer" >&2
    exit 1
  fi
  if ! [[ "$KEEPER_PRECHECK_DELAY_SEC" =~ ^[0-9]+$ ]] || [ "$KEEPER_PRECHECK_DELAY_SEC" -lt 0 ]; then
    echo "FAIL: KEEPER_PRECHECK_DELAY_SEC must be a non-negative integer" >&2
    exit 1
  fi
  if ! [[ "$KEEPER_PRECHECK_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || [ "$KEEPER_PRECHECK_TIMEOUT_SEC" -lt 1 ]; then
    echo "FAIL: KEEPER_PRECHECK_TIMEOUT_SEC must be a positive integer" >&2
    exit 1
  fi
  case "$KEEPER_PRECHECK_RECYCLE_ON_FAIL" in
    0|1|true|false|TRUE|FALSE|yes|no|YES|NO|on|off|ON|OFF) ;;
    *)
      echo "FAIL: KEEPER_PRECHECK_RECYCLE_ON_FAIL must be boolean-like (0/1/true/false)" >&2
      exit 1
      ;;
  esac
fi
if ! [[ "$STRICT_KEEPER_RECOVERY_MAX_RETRIES" =~ ^[0-9]+$ ]] || [ "$STRICT_KEEPER_RECOVERY_MAX_RETRIES" -lt 0 ]; then
  echo "FAIL: STRICT_KEEPER_RECOVERY_MAX_RETRIES must be a non-negative integer" >&2
  exit 1
fi
if ! [[ "$STRICT_KEEPER_RECOVERY_DELAY_SEC" =~ ^[0-9]+$ ]] || [ "$STRICT_KEEPER_RECOVERY_DELAY_SEC" -lt 0 ]; then
  echo "FAIL: STRICT_KEEPER_RECOVERY_DELAY_SEC must be a non-negative integer" >&2
  exit 1
fi
if ! [[ "$ROUND_RUN_RETRY_COUNT" =~ ^[0-9]+$ ]] || [ "$ROUND_RUN_RETRY_COUNT" -lt 1 ]; then
  echo "FAIL: ROUND_RUN_RETRY_COUNT must be a positive integer" >&2
  exit 1
fi
if [ "$ROUND_RUN_RETRY_COUNT" -gt 1 ] && [ "$(bool_to_json "$ROUND_RUN_ALLOW_MUTATING_RETRY")" != "true" ]; then
  echo "[bootstrap] clamp ROUND_RUN_RETRY_COUNT=1 for mutating trpg.round.run (set ROUND_RUN_ALLOW_MUTATING_RETRY=1 to override)"
  ROUND_RUN_RETRY_COUNT=1
fi
resolve_world_preset_id
if [ -n "$WORLD_PRESET_ID" ]; then
  echo "[bootstrap] world_preset_id=$WORLD_PRESET_ID"
fi
args_pool="$(jq -cn --arg sid "$SESSION_ID" --arg world "$WORLD_PRESET_ID" --arg dm "$DM_PRESET_ID" --argjson pool_size "$POOL_SIZE" --argjson party_size "$PARTY_SIZE" '
  {session_id:$sid,pool_size:$pool_size,party_size:$party_size}
  | if $world == "" then . else . + {world_preset_id:$world} end
  | if $dm == "" then . else . + {dm_preset_id:$dm} end
')"
r_pool="$(call_tool_checked 3001 "trpg.pool.generate" "$args_pool")"
pool="$(printf "%s" "$r_pool" | payload | jq -c '.pool')"
suggested="$(printf "%s" "$r_pool" | payload | jq -c '.suggested_party_ids')"

echo "[bootstrap] trpg.party.select"
args_party="$(jq -cn --arg sid "$SESSION_ID" --argjson pool "$pool" --argjson ids "$suggested" '{session_id:$sid,pool:$pool,selected_player_ids:$ids}')"
r_party="$(call_tool_checked 3002 "trpg.party.select" "$args_party")"
party="$(printf "%s" "$r_party" | payload | jq -c '.party')"

echo "[bootstrap] trpg.session.start"
args_start="$(jq -cn --arg sid "$SESSION_ID" --arg room "$ROOM_ID" --arg world "$WORLD_PRESET_ID" --arg dm "$DM_PRESET_ID" --argjson party "$party" '
  if $room == "" then
    {session_id:$sid,party:$party,phase:"briefing"}
  else
    {session_id:$sid,room_id:$room,party:$party,phase:"briefing",force:true}
  end
  | if $world == "" then . else . + {world_preset_id:$world} end
  | if $dm == "" then . else . + {dm_preset_id:$dm} end
  | . + {dm_keeper:$ENV.DM_KEEPER}
')"
r_start="$(call_tool_checked 3003 "trpg.session.start" "$args_start")"
room_id="$(printf "%s" "$r_start" | payload | jq -r '.room_id')"
world_used="$(printf "%s" "$r_start" | payload | jq -r '.world_preset.id // .world_preset.preset_id // "-"')"
dm_used="$(printf "%s" "$r_start" | payload | jq -r '.dm_preset.id // .dm_preset.preset_id // "-"')"
player_keepers_from_start="$(printf "%s" "$r_start" | payload | jq -c '.round_run_template.player_keepers // {}')"
if [ "$(printf "%s" "$player_keepers_from_start" | jq 'type == "object" and (length > 0)')" = "true" ]; then
  player_keepers="$player_keepers_from_start"
else
  player_keepers="$(printf "%s" "$party" | jq -c --arg tag "$KEEPER_TAG" '
    reduce .[] as $row ({}; . + {($row.actor_id): ("pk-" + $tag + "-" + $row.actor_id)})
  ')"
fi
PLAYER_KEEPER_NAMES="$(printf "%s" "$player_keepers" | jq -r '.[]' | awk 'NF')"
DM_KEEPER_INSTRUCTIONS="$(build_dm_instruction)"
PLAYER_KEEPER_INSTRUCTIONS="$(build_player_instruction)"
append_transcript_entry "session_start" "$(jq -cn --arg room_id "$room_id" --arg world "$world_used" --arg dm_preset "$dm_used" --arg dm_keeper "$DM_KEEPER" --argjson party "$party" --argjson player_keepers "$player_keepers" '{room_id:$room_id,world_preset:$world,dm_preset:$dm_preset,dm_keeper:$dm_keeper,party:$party,player_keepers:$player_keepers}')"

echo "[bootstrap] keeper up/claim"
call_tool_checked 3200 "masc_keeper_up" "$(jq -cn \
  --arg name "$DM_KEEPER" \
  --arg room "$room_id" \
  --arg instructions "$DM_KEEPER_INSTRUCTIONS" \
  --argjson models "$KEEPER_MODELS_JSON" \
  --argjson auto_handoff "$KEEPER_AUTO_HANDOFF_JSON" \
  --argjson handoff_threshold "$KEEPER_HANDOFF_THRESHOLD" \
  --argjson context_budget "$KEEPER_CONTEXT_BUDGET" \
  --arg compaction_profile "$KEEPER_COMPACTION_PROFILE" \
  --argjson compaction_ratio_gate "$KEEPER_COMPACTION_RATIO_GATE" \
  --argjson continuity_compaction_cooldown_sec "$KEEPER_CONTINUITY_COOLDOWN_SEC" \
  --argjson drift_enabled "$KEEPER_DRIFT_ENABLED_JSON" \
  '{name:$name,goal:("TRPG room " + $room + " DM keeper"),instructions:$instructions,models:$models,proactive_enabled:false,presence_keepalive:true,auto_handoff:$auto_handoff,handoff_threshold:$handoff_threshold,context_budget:$context_budget,compaction_profile:$compaction_profile,compaction_ratio_gate:$compaction_ratio_gate,continuity_compaction_cooldown_sec:$continuity_compaction_cooldown_sec,drift_enabled:$drift_enabled}')" >/dev/null
while IFS='|' read -r actor_id keeper_name; do
  [ -z "$actor_id" ] && continue
  [ -z "$keeper_name" ] && continue
  call_tool_checked 3201 "masc_keeper_up" "$(jq -cn \
    --arg name "$keeper_name" \
    --arg room "$room_id" \
    --arg actor "$actor_id" \
    --arg instructions "$PLAYER_KEEPER_INSTRUCTIONS" \
    --argjson models "$KEEPER_MODELS_JSON" \
    --argjson auto_handoff "$KEEPER_AUTO_HANDOFF_JSON" \
    --argjson handoff_threshold "$KEEPER_HANDOFF_THRESHOLD" \
    --argjson context_budget "$KEEPER_CONTEXT_BUDGET" \
    --arg compaction_profile "$KEEPER_COMPACTION_PROFILE" \
    --argjson compaction_ratio_gate "$KEEPER_COMPACTION_RATIO_GATE" \
    --argjson continuity_compaction_cooldown_sec "$KEEPER_CONTINUITY_COOLDOWN_SEC" \
    --argjson drift_enabled "$KEEPER_DRIFT_ENABLED_JSON" \
    '{name:$name,goal:("TRPG room " + $room + "에서 " + $actor + " actor를 플레이하세요."),instructions:$instructions,models:$models,proactive_enabled:false,presence_keepalive:true,auto_handoff:$auto_handoff,handoff_threshold:$handoff_threshold,context_budget:$context_budget,compaction_profile:$compaction_profile,compaction_ratio_gate:$compaction_ratio_gate,continuity_compaction_cooldown_sec:$continuity_compaction_cooldown_sec,drift_enabled:$drift_enabled}')" >/dev/null
  call_tool_checked 3202 "trpg.actor.claim" "$(jq -cn --arg room "$room_id" --arg actor "$actor_id" --arg keeper "$keeper_name" '{room_id:$room,actor_id:$actor,keeper_name:$keeper}')" >/dev/null
  CLAIMED_ACTORS="${CLAIMED_ACTORS}${CLAIMED_ACTORS:+$'\n'}${actor_id}|${keeper_name}"
done < <(printf "%s" "$player_keepers" | jq -r 'to_entries[] | "\(.key)|\(.value)"')

if [ "$KEEPER_PRECHECK_ENABLED" = "1" ]; then
  echo "[bootstrap] keeper precheck enabled retries=$KEEPER_PRECHECK_RETRIES timeout_sec=$KEEPER_PRECHECK_TIMEOUT_SEC"
  keeper_precheck_or_fail "$DM_KEEPER" "dm"
  while IFS='|' read -r actor_id keeper_name; do
    [ -z "$actor_id" ] && continue
    [ -z "$keeper_name" ] && continue
    keeper_precheck_or_fail "$keeper_name" "player:$actor_id"
  done <<< "$CLAIMED_ACTORS"
fi

round_template="$(jq -cn --arg room "$room_id" --arg dm "$DM_KEEPER" --argjson player_keepers "$player_keepers" '{room_id:$room,dm_keeper:$dm,player_keepers:$player_keepers}')"

echo "[bootstrap] room_id=$room_id world_preset=$world_used dm_preset=$dm_used require_claim=$REQUIRE_CLAIM_JSON"

if [ "$RUN_ROUND" = "1" ]; then
  echo "[round] RUN_ROUND=1, executing $ROUNDS rounds"
  round_local_fallback_json="$(bool_to_json "$ROUND_LOCAL_FALLBACK")"
  strict_agent_driven_json="$(bool_to_json "$REQUIRE_AGENT_DRIVEN")"
  i=1
  while [ "$i" -le "$ROUNDS" ]; do
    echo "  - round $i"
    round_recovery_attempt=0
    while :; do
      if [ -n "$(printf "%s" "$ROUND_KEEPER_TIMEOUT_SEC" | tr -d '[:space:]')" ]; then
        args_round="$(jq -cn --argjson t "$round_template" --argjson timeout "$ROUND_TIMEOUT_SEC" --argjson keeper_timeout "$ROUND_KEEPER_TIMEOUT_SEC" --argjson local_fallback "$round_local_fallback_json" --argjson strict_agent_driven "$strict_agent_driven_json" --argjson require_claim "$REQUIRE_CLAIM_JSON" --arg outcome_max_turn "$OUTCOME_MAX_TURN_EFFECTIVE" '{room_id:$t.room_id,dm_keeper:$t.dm_keeper,player_keepers:$t.player_keepers,phase:"round",timeout_sec:$timeout,keeper_timeout_sec:$keeper_timeout,require_claim:$require_claim,local_fallback:$local_fallback,strict_agent_driven:$strict_agent_driven} | if ($outcome_max_turn|length)>0 then . + {outcome_max_turn:($outcome_max_turn|tonumber)} else . end')"
      else
        args_round="$(jq -cn --argjson t "$round_template" --argjson timeout "$ROUND_TIMEOUT_SEC" --argjson local_fallback "$round_local_fallback_json" --argjson strict_agent_driven "$strict_agent_driven_json" --argjson require_claim "$REQUIRE_CLAIM_JSON" --arg outcome_max_turn "$OUTCOME_MAX_TURN_EFFECTIVE" '{room_id:$t.room_id,dm_keeper:$t.dm_keeper,player_keepers:$t.player_keepers,phase:"round",timeout_sec:$timeout,require_claim:$require_claim,local_fallback:$local_fallback,strict_agent_driven:$strict_agent_driven} | if ($outcome_max_turn|length)>0 then . + {outcome_max_turn:($outcome_max_turn|tonumber)} else . end')"
      fi
      r_round="$(call_tool $((4000 + i + round_recovery_attempt)) "trpg.round.run" "$args_round" "$ROUND_HTTP_TIMEOUT_SEC" "$ROUND_RUN_RETRY_COUNT")"
      round_err="$(tool_error_message "$r_round")"
      if [ -n "$round_err" ]; then
        round_failures=$((round_failures + 1))
        last_progress_reason="round_run_error"
        last_progress_detail="$round_err"
        stall_reason_lines="${stall_reason_lines}${stall_reason_lines:+$'\n'}round_run_error"
        append_transcript_entry "round_error" "$(jq -cn --argjson round "$i" --arg error "$round_err" --arg raw "$r_round" --argjson recovery_attempt "$round_recovery_attempt" '{round:$round,error:$error,raw:$raw,recovery_attempt:$recovery_attempt}')"
        echo "FAIL: trpg.round.run: $round_err"
        echo "[grimland-summary] $(emit_grimland_summary "fail")"
        printf "%s\n" "$r_round"
        exit 1
      fi
      p_round="$(printf "%s" "$r_round" | payload)"
      advanced="$(printf "%s" "$p_round" | jq -r '.summary.advanced // empty')"
      timeouts="$(printf "%s" "$p_round" | jq -r '.summary.timeouts // 0')"
      unavailable="$(printf "%s" "$p_round" | jq -r '.summary.unavailable // 0')"
      player_successes="$(printf "%s" "$p_round" | jq -r '.summary.player_successes // 0')"
      player_required="$(printf "%s" "$p_round" | jq -r '.summary.player_required_successes // 0')"
      dm_success="$(printf "%s" "$p_round" | jq -r '.summary.dm_success // false')"
      inferred_actions="$(printf "%s" "$p_round" | jq -r '.summary.inferred_actions // 0')"
      strict_rejection_count="$(printf "%s" "$p_round" | jq -r '.summary.strict_rejection_count // 0')"
      structured_noncompliance_count="$(printf "%s" "$p_round" | jq -r '[.statuses[]? | select((.status // "") == "schema_invalid" or (.status // "") == "rule_invalid")] | length')"
      regen_attempted="$(printf "%s" "$p_round" | jq -r '.summary.regen_attempted // 0')"
      regen_succeeded="$(printf "%s" "$p_round" | jq -r '.summary.regen_succeeded // false')"
      progress_reason="$(printf "%s" "$p_round" | jq -r '.summary.progress_reason // empty')"
      progress_detail="$(printf "%s" "$p_round" | jq -r '.summary.progress_detail // empty')"
      dm_progress_detail="$(printf "%s" "$p_round" | jq -r '.summary.dm_progress_detail // empty')"
      dm_non_ok_statuses="$(printf "%s" "$p_round" | jq -c '.summary.dm_non_ok_statuses // []')"
      validation_failure_reason="$(printf "%s" "$p_round" | jq -r '.summary.validation_failure_reason // empty')"
      validation_failure_stage="$(printf "%s" "$p_round" | jq -r '.summary.validation_failure_stage // empty')"
      recovery_mode="$(printf "%s" "$p_round" | jq -r '.summary.recovery_mode // empty')"
      round_outcome="$(printf "%s" "$p_round" | jq -r '.outcome.outcome // empty')"
      round_outcome_reason="$(printf "%s" "$p_round" | jq -r '.outcome.reason // empty')"
      room_status="$(printf "%s" "$p_round" | jq -r '.room_status // empty')"

      if [ -n "$progress_reason" ]; then
        stall_reason_lines="${stall_reason_lines}${stall_reason_lines:+$'\n'}${progress_reason}"
        last_progress_reason="$progress_reason"
      fi
      if [ -n "$progress_detail" ]; then
        last_progress_detail="$progress_detail"
      fi
      if [ -n "$dm_progress_detail" ]; then
        last_dm_progress_detail="$dm_progress_detail"
      fi
      if [ "$(printf "%s" "$dm_non_ok_statuses" | jq 'type == "array" and length > 0')" = "true" ]; then
        last_dm_non_ok_statuses="$dm_non_ok_statuses"
      fi
      if [ -n "$validation_failure_reason" ]; then
        last_validation_failure_reason="$validation_failure_reason"
      fi
      if [ -n "$validation_failure_stage" ]; then
        last_validation_failure_stage="$validation_failure_stage"
      fi

      if [ -z "$advanced" ]; then
        turn_before="$(printf "%s" "$p_round" | jq -r '.turn_before // 0')"
        turn_after="$(printf "%s" "$p_round" | jq -r '.turn_after // 0')"
        if [ "${turn_after:-0}" -gt "${turn_before:-0}" ]; then
          advanced="true"
        else
          advanced="false"
        fi
      else
        turn_before="$(printf "%s" "$p_round" | jq -r '.turn_before // 0')"
        turn_after="$(printf "%s" "$p_round" | jq -r '.turn_after // 0')"
      fi

      append_transcript_entry "round_result" "$(jq -cn --argjson round "$i" --argjson payload "$p_round" --argjson recovery_attempt "$round_recovery_attempt" '{
        round:$round,
        recovery_attempt:$recovery_attempt,
        turn_before:($payload.turn_before // 0),
        turn_after:($payload.turn_after // 0),
        room_status:($payload.room_status // null),
        outcome:($payload.outcome // null),
        summary:($payload.summary // {}),
        statuses:[($payload.statuses // [])[] | {
          actor_id:(.actor_id // null),
          role:(.role // null),
          keeper:(.keeper // null),
          status:(.status // null),
          reason:(.reason // null),
          action_type:(.action_type // null),
          reply:(.reply // null)
        }],
        narrative_events:[($payload.events // [])[] | {
          type:(.type // null),
          actor_id:(.actor_id // null),
          actor_name:(.actor_name // null),
          content:(.content // null),
          payload:(.payload // null)
        }]
      }')"

      echo "    turn=${turn_before:-?}->${turn_after:-?} advanced=$advanced reason=${progress_reason:-none} mode=${recovery_mode:-none} players=${player_successes}/${player_required} dm=${dm_success} inferred_actions=$inferred_actions strict_rejections=$strict_rejection_count structured_noncompliance=$structured_noncompliance_count regen=${regen_attempted}/${regen_succeeded} timeouts=$timeouts unavailable=$unavailable outcome=${round_outcome:-none} recovery_attempt=$round_recovery_attempt"

      inferred_actions_total=$((inferred_actions_total + inferred_actions))
      strict_rejection_total=$((strict_rejection_total + strict_rejection_count))
      timeout_total=$((timeout_total + timeouts))
      unavailable_total=$((unavailable_total + unavailable))

      if [ "$REQUIRE_NO_HEURISTIC" = "1" ] && [ "$inferred_actions" -gt 0 ]; then
        no_heuristic_violations=$((no_heuristic_violations + 1))
        echo "FAIL: round $i used heuristic inferred action(s) (count=$inferred_actions)" >&2
        echo "[grimland-summary] $(emit_grimland_summary "fail")"
        exit 1
      fi

      if [ "$inferred_actions" -gt 0 ]; then
        no_heuristic_violations=$((no_heuristic_violations + 1))
      fi

      strict_recovery_trigger=0
      if [ "$advanced" != "true" ] && { [ "${strict_rejection_count:-0}" -gt 0 ] \
        || [ "${structured_noncompliance_count:-0}" -gt 0 ] \
        || [ "${progress_reason:-}" = "structured_action_invalid" ] \
        || [ "${progress_reason:-}" = "keeper_unavailable" ] \
        || [ "${progress_reason:-}" = "timeout" ] \
        || [ "${timeouts:-0}" -gt 0 ] \
        || [ "${unavailable:-0}" -gt 0 ]; }; then
        strict_recovery_trigger=1
      fi

      if [ "$REQUIRE_AGENT_DRIVEN" = "1" ] \
        && [ "$STRICT_KEEPER_RECOVERY_ENABLED" = "1" ] \
        && [ "$strict_recovery_trigger" -eq 1 ] \
        && [ "$round_recovery_attempt" -lt "$STRICT_KEEPER_RECOVERY_MAX_RETRIES" ]; then
        round_recovery_attempt=$((round_recovery_attempt + 1))
        strict_keeper_recovery_attempts=$((strict_keeper_recovery_attempts + 1))
        if recover_keepers_from_noncompliance "$p_round" "$i" "$round_recovery_attempt"; then
          strict_keeper_recovery_successes=$((strict_keeper_recovery_successes + 1))
          if [ "$STRICT_KEEPER_RECOVERY_DELAY_SEC" -gt 0 ]; then
            sleep "$STRICT_KEEPER_RECOVERY_DELAY_SEC"
          fi
          continue
        else
          strict_keeper_recovery_failures=$((strict_keeper_recovery_failures + 1))
        fi
      fi

      round_agent_violation=0
      round_agent_violation_reason=""
      if [ "$recovery_mode" = "local_fallback_applied" ]; then
        local_fallback_applied_total=$((local_fallback_applied_total + 1))
        round_agent_violation=1
        round_agent_violation_reason="${round_agent_violation_reason}${round_agent_violation_reason:+,}local_fallback_applied"
      fi
      if [ "$dm_success" != "true" ]; then
        dm_failed_rounds=$((dm_failed_rounds + 1))
        round_agent_violation=1
        round_agent_violation_reason="${round_agent_violation_reason}${round_agent_violation_reason:+,}dm_failed"
      fi
      if [ "$player_successes" -lt "$player_required" ]; then
        incomplete_party_rounds=$((incomplete_party_rounds + 1))
        round_agent_violation=1
        round_agent_violation_reason="${round_agent_violation_reason}${round_agent_violation_reason:+,}player_shortfall"
      fi
      if [ "${strict_rejection_count:-0}" -gt 0 ] || [ "${structured_noncompliance_count:-0}" -gt 0 ]; then
        round_agent_violation=1
        if [ "${strict_rejection_count:-0}" -gt 0 ]; then
          round_agent_violation_reason="${round_agent_violation_reason}${round_agent_violation_reason:+,}strict_rejection"
        fi
        if [ "${structured_noncompliance_count:-0}" -gt 0 ]; then
          round_agent_violation_reason="${round_agent_violation_reason}${round_agent_violation_reason:+,}structured_noncompliance"
        fi
      fi
      if [ "$round_agent_violation" -eq 1 ]; then
        agent_driven_violations=$((agent_driven_violations + 1))
      fi

      if [ "$REQUIRE_AGENT_DRIVEN" = "1" ] && [ "$round_agent_violation" -eq 1 ]; then
        echo "FAIL: round $i violates agent-driven policy ($round_agent_violation_reason)" >&2
        echo "[grimland-summary] $(emit_grimland_summary "fail")"
        exit 1
      fi
      if [ "$REQUIRE_AGENT_DRIVEN" = "1" ] && { [ "${strict_rejection_count:-0}" -gt 0 ] || [ "${structured_noncompliance_count:-0}" -gt 0 ]; }; then
        echo "FAIL: round $i strict rejection detected (strict_rejection_count=$strict_rejection_count structured_noncompliance_count=$structured_noncompliance_count stage=${validation_failure_stage:-unknown} reason=${validation_failure_reason:-unknown})" >&2
        echo "[grimland-summary] $(emit_grimland_summary "fail")"
        exit 1
      fi

      full_party_ok="true"
      if [ "$player_successes" -lt "$player_required" ] || [ "$dm_success" != "true" ]; then
        full_party_ok="false"
      fi
      if [ "$REQUIRE_FULL_PARTY_SUCCESS" = "1" ] && [ "$full_party_ok" != "true" ]; then
        echo "FAIL: round $i missing full-party response (players=$player_successes/$player_required dm=$dm_success)" >&2
        echo "[grimland-summary] $(emit_grimland_summary "fail")"
        exit 1
      fi
      if [ "$advanced" = "false" ]; then
        round_failures=$((round_failures + 1))
        first_issue="$(printf "%s" "$p_round" | jq -r '[.statuses[]? | select(.status != "ok" and .status != "skipped") | (.reason // .status // empty)] | map(select(. != null and . != "")) | .[0] // empty')"
        blocked_statuses="$(printf "%s" "$p_round" | jq -c '[.statuses[]? | select(.status != "ok" and .status != "skipped") | {actor:.actor,status:.status,reason:.reason}]')"
        echo "FAIL: round $i did not advance (player_successes=$player_successes dm_success=$dm_success timeouts=$timeouts unavailable=$unavailable progress=${progress_reason:-none})"
        if [ -n "$blocked_statuses" ] && [ "$blocked_statuses" != "null" ]; then
          echo "blocked_statuses=$blocked_statuses"
        fi
        if [ -n "$first_issue" ]; then
          echo "hint: first issue => $first_issue"
        fi
        if [ -n "$progress_reason" ]; then
          echo "hint: progress_reason => $progress_reason"
        fi
        echo "[grimland-summary] $(emit_grimland_summary "fail")"
        printf "%s\n" "$r_round"
        exit 1
      fi

      rounds_completed=$((rounds_completed + 1))
      if [ -n "$round_outcome" ] || [ "$room_status" = "ended" ]; then
        session_outcome_seen="true"
        [ -n "$round_outcome" ] && last_outcome="$round_outcome"
        [ -n "$round_outcome_reason" ] && last_outcome_reason="$round_outcome_reason"
        echo "  - session outcome observed (outcome=${round_outcome:-unknown} reason=${round_outcome_reason:-none})"
      fi
      break
    done
    if [ "$session_outcome_seen" = "true" ]; then
      break
    fi
    i=$((i + 1))
  done
fi

echo "[intervention] trpg.intervention.submit"
call_tool_checked 3500 "trpg.intervention.submit" "{\"room_id\":\"$room_id\",\"session_id\":\"$SESSION_ID\",\"intervention_type\":\"nudge\",\"payload\":{\"target\":\"trust\",\"delta\":0.1}}" >/dev/null

echo "[stream] trpg.stream.read"
r_stream="$(call_tool_checked 3600 "trpg.stream.read" "{\"room_id\":\"$room_id\"}")"
p_stream="$(printf "%s" "$r_stream" | payload)"
stream_count="$(printf "%s" "$p_stream" | jq -r '.count // 0')"
stream_outcome_seen="$(printf "%s" "$p_stream" | jq -r '[.events[]? | (.type // "") | select(. == "session.outcome" or . == "session.ended" or . == "session.end")] | length > 0')"
if [ "$stream_outcome_seen" = "true" ]; then
  session_outcome_seen="true"
fi
if [ -z "$last_outcome" ]; then
  last_outcome="$(printf "%s" "$p_stream" | jq -r '[.events[]? | select((.type // "") == "session.outcome") | (.payload.outcome // empty)] | last // empty')"
fi
if [ -z "$last_outcome_reason" ]; then
  last_outcome_reason="$(printf "%s" "$p_stream" | jq -r '[.events[]? | select((.type // "") == "session.outcome") | (.payload.reason // empty)] | last // empty')"
fi
append_transcript_entry "stream_dialogue" "$(printf "%s" "$p_stream" | jq -c '{
  count:(.count // 0),
  events:[.events[]? | {
    seq:(.seq // null),
    type:(.type // null),
    actor_id:(.actor_id // .payload.actor_id // null),
    actor_name:(.actor_name // .payload.actor_name // null),
    phase:(.phase // .payload.phase // null),
    text:(.payload.text // .payload.reply // .payload.summary // .payload.description // .payload.narration // .content // .text // null),
    payload:(.payload // null)
  } | select((.text // "") != "")]
}')"
if [ "$RUN_ROUND" = "1" ] && [ "$REQUIRE_SESSION_OUTCOME" = "1" ] && [ "$session_outcome_seen" != "true" ]; then
  echo "FAIL: session outcome was not observed after $rounds_completed round(s)" >&2
  echo "[grimland-summary] $(emit_grimland_summary "fail")"
  exit 1
fi
echo "[grimland-summary] $(emit_grimland_summary "pass")"

echo "PASS: trpg smoke (events=$stream_count, room_id=$room_id, world_preset=$world_used, dm_preset=$dm_used, run_round=$RUN_ROUND)"
