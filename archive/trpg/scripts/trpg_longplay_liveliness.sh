#!/usr/bin/env bash
set -euo pipefail

MCP_URL="${MCP_URL:-http://127.0.0.1:8935/mcp}"
SESSION_ID="${SESSION_ID:-longplay-grimland-$(date +%s)}"
ROOM_ID="${ROOM_ID:-}"
ROUNDS="${ROUNDS:-20}"
WORLD_PRESET_ID="${WORLD_PRESET_ID:-}"
DM_PRESET_ID="${DM_PRESET_ID:-}"
PARTY_SIZE="${PARTY_SIZE:-4}"
POOL_SIZE="${POOL_SIZE:-6}"
KEEPER_TAG="${KEEPER_TAG:-longplay-$(date +%s)}"
DM_KEEPER="${DM_KEEPER:-dm-$KEEPER_TAG}"
ROUND_TIMEOUT_SEC="${ROUND_TIMEOUT_SEC:-45}"
ROUND_HTTP_TIMEOUT_SEC="${ROUND_HTTP_TIMEOUT_SEC:-$((ROUND_TIMEOUT_SEC + 180))}"
KEEPER_MODELS="${KEEPER_MODELS:-}"
LOCAL_FALLBACK="${LOCAL_FALLBACK:-false}"
STRICT_ADVANCE="${STRICT_ADVANCE:-true}"
ENFORCE_DISTRIBUTION="${ENFORCE_DISTRIBUTION:-false}"
MIN_UNIQUE_DAMAGED_PLAYERS="${MIN_UNIQUE_DAMAGED_PLAYERS:-2}"
REPORT_PATH="${REPORT_PATH:-}"
KEEPER_AUTO_HANDOFF="${KEEPER_AUTO_HANDOFF:-1}"
KEEPER_HANDOFF_THRESHOLD="${KEEPER_HANDOFF_THRESHOLD:-0.82}"
KEEPER_CONTEXT_BUDGET="${KEEPER_CONTEXT_BUDGET:-0.70}"
KEEPER_COMPACTION_PROFILE="${KEEPER_COMPACTION_PROFILE:-balanced}"
KEEPER_COMPACTION_RATIO_GATE="${KEEPER_COMPACTION_RATIO_GATE:-0.72}"
KEEPER_CONTINUITY_COOLDOWN_SEC="${KEEPER_CONTINUITY_COOLDOWN_SEC:-180}"
KEEPER_DRIFT_ENABLED="${KEEPER_DRIFT_ENABLED:-0}"

PLAYER_KEEPER_NAMES=""
CLAIMED_ACTORS=""

CURL_TIMEOUT_SEC="${CURL_TIMEOUT_SEC:-120}"
CURL_RETRY_COUNT="${CURL_RETRY_COUNT:-12}"
CURL_RETRY_DELAY_SEC="${CURL_RETRY_DELAY_SEC:-1}"

normalize_bool() {
  local raw="${1:-false}"
  local lower
  lower="$(printf "%s" "$raw" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    1|true|yes|y|on) printf "true" ;;
    *) printf "false" ;;
  esac
}

cleanup_keepers() {
  if [ -n "${room_id:-}" ] && [ -n "${CLAIMED_ACTORS:-}" ]; then
    while IFS='|' read -r actor_id keeper_name; do
      [ -z "$actor_id" ] && continue
      [ -z "$keeper_name" ] && continue
      call_tool 4801 "trpg.actor.release" "$(jq -cn --arg room "$room_id" --arg actor "$actor_id" --arg keeper "$keeper_name" '{room_id:$room,actor_id:$actor,keeper_name:$keeper}')" >/dev/null 2>&1 || true
    done <<< "$CLAIMED_ACTORS"
  fi
  if [ -n "${DM_KEEPER:-}" ]; then
    call_tool 4802 "masc_keeper_down" "$(jq -cn --arg name "$DM_KEEPER" '{name:$name,remove_meta:true,remove_session:true}')" >/dev/null 2>&1 || true
  fi
  if [ -n "${PLAYER_KEEPER_NAMES:-}" ]; then
    while IFS= read -r keeper_name; do
      [ -z "$keeper_name" ] && continue
      call_tool 4803 "masc_keeper_down" "$(jq -cn --arg name "$keeper_name" '{name:$name,remove_meta:true,remove_session:true}')" >/dev/null 2>&1 || true
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

build_models_json() {
  jq -cn --arg csv "$KEEPER_MODELS" '
    $csv
    | split(",")
    | map(gsub("^\\s+|\\s+$";""))
    | map(select(length > 0))
  '
}

count_unique_lines() {
  local raw="$1"
  printf "%s\n" "$raw" | awk 'NF' | sort -u | wc -l | LC_ALL=C tr -d ' '
}

LOCAL_FALLBACK_BOOL="$(normalize_bool "$LOCAL_FALLBACK")"
STRICT_ADVANCE_BOOL="$(normalize_bool "$STRICT_ADVANCE")"
ENFORCE_DISTRIBUTION_BOOL="$(normalize_bool "$ENFORCE_DISTRIBUTION")"
KEEPER_MODELS_JSON="$(build_models_json)"
KEEPER_AUTO_HANDOFF_BOOL="$(normalize_bool "$KEEPER_AUTO_HANDOFF")"
KEEPER_DRIFT_ENABLED_BOOL="$(normalize_bool "$KEEPER_DRIFT_ENABLED")"

if [ "$(printf "%s" "$KEEPER_MODELS_JSON" | jq 'length')" -eq 0 ]; then
  echo "FAIL: KEEPER_MODELS is required (예: KEEPER_MODELS='gemini:gemini-2.5-flash')" >&2
  exit 1
fi
if [ "$POOL_SIZE" -lt "$PARTY_SIZE" ]; then
  POOL_SIZE="$PARTY_SIZE"
fi
if [ "$ROUNDS" -lt 1 ]; then
  echo "FAIL: ROUNDS must be >= 1" >&2
  exit 1
fi

echo "[longplay] trpg.pool.generate"
args_pool="$(jq -cn --arg sid "$SESSION_ID" --arg world "$WORLD_PRESET_ID" --arg dm "$DM_PRESET_ID" --argjson pool_size "$POOL_SIZE" --argjson party_size "$PARTY_SIZE" '
  {session_id:$sid,pool_size:$pool_size,party_size:$party_size}
  | if $world == "" then . else . + {world_preset_id:$world} end
  | if $dm == "" then . else . + {dm_preset_id:$dm} end
')"
r_pool="$(call_tool_checked 4101 "trpg.pool.generate" "$args_pool")"
pool="$(printf "%s" "$r_pool" | payload | jq -c '.pool')"
suggested="$(printf "%s" "$r_pool" | payload | jq -c '.suggested_party_ids')"

echo "[longplay] trpg.party.select"
args_party="$(jq -cn --arg sid "$SESSION_ID" --argjson pool "$pool" --argjson ids "$suggested" '{session_id:$sid,pool:$pool,selected_player_ids:$ids}')"
r_party="$(call_tool_checked 4102 "trpg.party.select" "$args_party")"
party="$(printf "%s" "$r_party" | payload | jq -c '.party')"

echo "[longplay] trpg.session.start"
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
r_start="$(call_tool_checked 4103 "trpg.session.start" "$args_start")"
room_id="$(printf "%s" "$r_start" | payload | jq -r '.room_id')"
world_used="$(printf "%s" "$r_start" | payload | jq -r '.world_preset.id // .world_preset.preset_id // "-"')"
dm_used="$(printf "%s" "$r_start" | payload | jq -r '.dm_preset.id // .dm_preset.preset_id // "-"')"
player_keepers="$(printf "%s" "$party" | jq -c --arg tag "$KEEPER_TAG" '
  reduce .[] as $row ({}; . + {($row.actor_id): ("pk-" + $tag + "-" + $row.actor_id)})
')"
PLAYER_KEEPER_NAMES="$(printf "%s" "$player_keepers" | jq -r '.[]' | awk 'NF')"

echo "[longplay] keeper up/claim"
call_tool_checked 4200 "masc_keeper_up" "$(jq -cn \
  --arg name "$DM_KEEPER" \
  --arg room "$room_id" \
  --argjson models "$KEEPER_MODELS_JSON" \
  --argjson auto_handoff "$KEEPER_AUTO_HANDOFF_BOOL" \
  --argjson handoff_threshold "$KEEPER_HANDOFF_THRESHOLD" \
  --argjson context_budget "$KEEPER_CONTEXT_BUDGET" \
  --arg compaction_profile "$KEEPER_COMPACTION_PROFILE" \
  --argjson compaction_ratio_gate "$KEEPER_COMPACTION_RATIO_GATE" \
  --argjson continuity_compaction_cooldown_sec "$KEEPER_CONTINUITY_COOLDOWN_SEC" \
  --argjson drift_enabled "$KEEPER_DRIFT_ENABLED_BOOL" \
  '{name:$name,goal:("TRPG room " + $room + " DM keeper"),instructions:"모든 응답은 한국어로 작성하세요. 당신은 DM으로서 서사를 전개하고 턴 정체를 피해야 합니다.",models:$models,proactive_enabled:false,presence_keepalive:true,auto_handoff:$auto_handoff,handoff_threshold:$handoff_threshold,context_budget:$context_budget,compaction_profile:$compaction_profile,compaction_ratio_gate:$compaction_ratio_gate,continuity_compaction_cooldown_sec:$continuity_compaction_cooldown_sec,drift_enabled:$drift_enabled}')" >/dev/null
while IFS='|' read -r actor_id keeper_name; do
  [ -z "$actor_id" ] && continue
  [ -z "$keeper_name" ] && continue
  call_tool_checked 4201 "masc_keeper_up" "$(jq -cn \
    --arg name "$keeper_name" \
    --arg room "$room_id" \
    --arg actor "$actor_id" \
    --argjson models "$KEEPER_MODELS_JSON" \
    --argjson auto_handoff "$KEEPER_AUTO_HANDOFF_BOOL" \
    --argjson handoff_threshold "$KEEPER_HANDOFF_THRESHOLD" \
    --argjson context_budget "$KEEPER_CONTEXT_BUDGET" \
    --arg compaction_profile "$KEEPER_COMPACTION_PROFILE" \
    --argjson compaction_ratio_gate "$KEEPER_COMPACTION_RATIO_GATE" \
    --argjson continuity_compaction_cooldown_sec "$KEEPER_CONTINUITY_COOLDOWN_SEC" \
    --argjson drift_enabled "$KEEPER_DRIFT_ENABLED_BOOL" \
    '{name:$name,goal:("TRPG room " + $room + "에서 " + $actor + " actor를 플레이하세요."),instructions:"모든 응답은 한국어로 작성하세요. 당신은 보조자가 아니라 해당 액터를 직접 플레이하는 주체입니다.",models:$models,proactive_enabled:false,presence_keepalive:true,auto_handoff:$auto_handoff,handoff_threshold:$handoff_threshold,context_budget:$context_budget,compaction_profile:$compaction_profile,compaction_ratio_gate:$compaction_ratio_gate,continuity_compaction_cooldown_sec:$continuity_compaction_cooldown_sec,drift_enabled:$drift_enabled}')" >/dev/null
  call_tool_checked 4202 "trpg.actor.claim" "$(jq -cn --arg room "$room_id" --arg actor "$actor_id" --arg keeper "$keeper_name" '{room_id:$room,actor_id:$actor,keeper_name:$keeper}')" >/dev/null
  CLAIMED_ACTORS="${CLAIMED_ACTORS}${CLAIMED_ACTORS:+$'\n'}${actor_id}|${keeper_name}"
done < <(printf "%s" "$player_keepers" | jq -r 'to_entries[] | "\(.key)|\(.value)"')

echo "[longplay] room_id=$room_id world=$world_used dm_preset=$dm_used rounds=$ROUNDS local_fallback=$LOCAL_FALLBACK_BOOL"

round_failures=0
timeout_total=0
unavailable_total=0
placeholder_total=0
recovery_applied_total=0
roll_audit_total=0
npc_spawn_total=0
npc_attack_total=0
all_damaged_players=""
all_targets=""
all_player_replies=""
stall_reason_lines=""

i=1
while [ "$i" -le "$ROUNDS" ]; do
  args_round="$(jq -cn --arg room "$room_id" --arg dm "$DM_KEEPER" --argjson players "$player_keepers" --argjson timeout "$ROUND_TIMEOUT_SEC" --argjson local_fallback "$LOCAL_FALLBACK_BOOL" '
    {
      room_id:$room,
      dm_keeper:$dm,
      player_keepers:$players,
      phase:"round",
      timeout_sec:$timeout,
      require_claim:true,
      local_fallback:$local_fallback
    }
  ')"
  r_round="$(call_tool_checked $((4300 + i)) "trpg.round.run" "$args_round" "$ROUND_HTTP_TIMEOUT_SEC" "1")"
  p_round="$(printf "%s" "$r_round" | payload)"

  turn_before="$(printf "%s" "$p_round" | jq -r '.turn_before // 0')"
  turn_after="$(printf "%s" "$p_round" | jq -r '.turn_after // 0')"
  advanced="$(printf "%s" "$p_round" | jq -r '.summary.advanced // empty')"
  if [ -z "$advanced" ]; then
    if [ "$turn_after" -gt "$turn_before" ]; then
      advanced="true"
    else
      advanced="false"
    fi
  fi
  if [ "$advanced" != "true" ]; then
    round_failures=$((round_failures + 1))
  fi
  progress_reason="$(printf "%s" "$p_round" | jq -r '.summary.progress_reason // ""')"
  recovery_applied="$(printf "%s" "$p_round" | jq -r '.summary.recovery_applied // false')"
  recovery_mode="$(printf "%s" "$p_round" | jq -r '.summary.recovery_mode // ""')"
  effective_timeout="$(printf "%s" "$p_round" | jq -r '.summary.effective_timeout_sec // .timeout_sec // 0')"
  roll_audit_round="$(printf "%s" "$p_round" | jq -r '.summary.roll_audit_count // 0')"
  npc_spawn_round="$(printf "%s" "$p_round" | jq -r '.summary.npc_spawned // 0')"
  npc_attack_round="$(printf "%s" "$p_round" | jq -r '.summary.npc_attacks // 0')"
  if [ "$advanced" != "true" ] && [ -n "$progress_reason" ]; then
    stall_reason_lines="${stall_reason_lines}${stall_reason_lines:+$'\n'}${progress_reason}"
  fi

  timeouts="$(printf "%s" "$p_round" | jq -r '.summary.timeouts // 0')"
  unavailable="$(printf "%s" "$p_round" | jq -r '.summary.unavailable // 0')"
  timeout_total=$((timeout_total + timeouts))
  unavailable_total=$((unavailable_total + unavailable))
  roll_audit_total=$((roll_audit_total + roll_audit_round))
  npc_spawn_total=$((npc_spawn_total + npc_spawn_round))
  npc_attack_total=$((npc_attack_total + npc_attack_round))
  if [ "$recovery_applied" = "true" ]; then
    recovery_applied_total=$((recovery_applied_total + 1))
  fi

  placeholder_round="$(printf "%s" "$p_round" | jq -r '[.statuses[]? | select((.reply // "") | contains("상황을 살피며 다음 행동을 준비합니다"))] | length')"
  placeholder_total=$((placeholder_total + placeholder_round))

  damaged_round="$(printf "%s" "$p_round" | jq -r '.state.party | to_entries[] | select(.value.role != "npc" and ((.value.hp // 0) < (.value.max_hp // 0))) | .key')"
  targets_round="$(printf "%s" "$p_round" | jq -r '.events[]? | select(.type=="combat.attack") | (.payload.target_id // .target_id // empty)')"
  player_replies_round="$(printf "%s" "$p_round" | jq -r '.statuses[]? | select(.role=="player") | .reply // empty')"

  [ -n "$damaged_round" ] && all_damaged_players="${all_damaged_players}${all_damaged_players:+$'\n'}${damaged_round}"
  [ -n "$targets_round" ] && all_targets="${all_targets}${all_targets:+$'\n'}${targets_round}"
  [ -n "$player_replies_round" ] && all_player_replies="${all_player_replies}${all_player_replies:+$'\n'}${player_replies_round}"

  damaged_now="$(printf "%s\n" "$damaged_round" | awk 'NF' | wc -l | LC_ALL=C tr -d ' ')"
  echo "[round $i] turn ${turn_before}->${turn_after} advanced=$advanced reason=${progress_reason:-none} recovery=$recovery_applied mode=${recovery_mode:-none} timeout=${effective_timeout}s timeouts=$timeouts unavailable=$unavailable roll_audit=$roll_audit_round npc_spawn=$npc_spawn_round npc_attack=$npc_attack_round damaged_players_now=$damaged_now placeholder=$placeholder_round"

  i=$((i + 1))
done

advanced_rounds=$((ROUNDS - round_failures))
advanced_ratio="$(awk "BEGIN{if ($ROUNDS == 0) {printf \"0.000\"} else {printf \"%.3f\", $advanced_rounds / $ROUNDS}}")"

unique_damaged_count="$(count_unique_lines "$all_damaged_players")"
unique_target_count="$(count_unique_lines "$all_targets")"
unique_reply_count="$(count_unique_lines "$all_player_replies")"
unique_stall_reasons="$(count_unique_lines "$stall_reason_lines")"

summary_json="$(
  jq -cn \
    --arg room_id "$room_id" \
    --arg session_id "$SESSION_ID" \
    --arg world_preset "$world_used" \
    --arg dm_preset "$dm_used" \
    --arg dm_keeper "$DM_KEEPER" \
    --argjson rounds "$ROUNDS" \
    --argjson advanced_rounds "$advanced_rounds" \
    --argjson failed_rounds "$round_failures" \
    --arg advanced_ratio "$advanced_ratio" \
    --argjson timeout_total "$timeout_total" \
    --argjson unavailable_total "$unavailable_total" \
    --argjson placeholder_total "$placeholder_total" \
    --argjson recovery_applied_total "$recovery_applied_total" \
    --argjson roll_audit_total "$roll_audit_total" \
    --argjson npc_spawn_total "$npc_spawn_total" \
    --argjson npc_attack_total "$npc_attack_total" \
    --argjson unique_damaged_players "$unique_damaged_count" \
    --argjson unique_targets "$unique_target_count" \
    --argjson unique_player_replies "$unique_reply_count" \
    --argjson unique_stall_reasons "$unique_stall_reasons" \
    --arg local_fallback "$LOCAL_FALLBACK_BOOL" \
    '{
      room_id:$room_id,
      session_id:$session_id,
      world_preset:$world_preset,
      dm_preset:$dm_preset,
      dm_keeper:$dm_keeper,
      rounds:$rounds,
      advanced_rounds:$advanced_rounds,
      failed_rounds:$failed_rounds,
      advanced_ratio:$advanced_ratio,
      timeout_total:$timeout_total,
      unavailable_total:$unavailable_total,
      placeholder_total:$placeholder_total,
      recovery_applied_total:$recovery_applied_total,
      roll_audit_total:$roll_audit_total,
      npc_spawn_total:$npc_spawn_total,
      npc_attack_total:$npc_attack_total,
      unique_damaged_players:$unique_damaged_players,
      unique_targets:$unique_targets,
      unique_player_replies:$unique_player_replies,
      unique_stall_reasons:$unique_stall_reasons,
      local_fallback:$local_fallback
    }'
)"

echo "[longplay-summary] $summary_json"

if [ -n "$REPORT_PATH" ]; then
  printf "%s\n" "$summary_json" > "$REPORT_PATH"
  echo "[longplay] wrote report: $REPORT_PATH"
fi

exit_code=0
if [ "$STRICT_ADVANCE_BOOL" = "true" ] && [ "$round_failures" -gt 0 ]; then
  echo "FAIL: strict advance enabled but failed_rounds=$round_failures" >&2
  exit_code=1
fi
if [ "$ENFORCE_DISTRIBUTION_BOOL" = "true" ] && [ "$unique_damaged_count" -lt "$MIN_UNIQUE_DAMAGED_PLAYERS" ]; then
  echo "FAIL: distribution gate not met (unique_damaged_players=$unique_damaged_count < min=$MIN_UNIQUE_DAMAGED_PLAYERS)" >&2
  exit_code=1
fi

if [ "$exit_code" -eq 0 ]; then
  echo "PASS: trpg longplay liveliness workload"
fi

exit "$exit_code"
