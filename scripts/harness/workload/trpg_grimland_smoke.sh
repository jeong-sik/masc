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
ROUND_TIMEOUT_SEC="${ROUND_TIMEOUT_SEC:-12}"
KEEPER_MODELS="${KEEPER_MODELS:-}"
PLAYER_KEEPER_NAMES=""
CURL_TIMEOUT_SEC="${CURL_TIMEOUT_SEC:-120}"
CURL_RETRY_COUNT="${CURL_RETRY_COUNT:-12}"
CURL_RETRY_DELAY_SEC="${CURL_RETRY_DELAY_SEC:-1}"

cleanup_keepers() {
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
  local raw=""
  local sse_data
  local attempt=1
  while [ "$attempt" -le "$CURL_RETRY_COUNT" ]; do
    if raw="$(curl -sS -m "$CURL_TIMEOUT_SEC" -X POST "$MCP_URL" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -d "{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":\"tools/call\",\"params\":{\"name\":\"$name\",\"arguments\":$args_json}}")"; then
      break
    fi
    if [ "$attempt" -lt "$CURL_RETRY_COUNT" ]; then
      sleep "$CURL_RETRY_DELAY_SEC"
    fi
    attempt=$((attempt + 1))
  done
  if [ -z "$raw" ]; then
    printf '{"error":{"message":"curl failed after retries: tool=%s timeout_sec=%s retries=%s"}}' "$name" "$CURL_TIMEOUT_SEC" "$CURL_RETRY_COUNT"
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
  local raw
  local err
  raw="$(call_tool "$id" "$name" "$args_json")"
  if [ -z "$(printf "%s" "$raw" | tr -d '[:space:]')" ]; then
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

echo "[bootstrap] trpg.pool.generate"
if [ "$POOL_SIZE" -lt "$PARTY_SIZE" ]; then
  POOL_SIZE="$PARTY_SIZE"
fi
KEEPER_MODELS_JSON="$(build_models_json)"
if [ "$(printf "%s" "$KEEPER_MODELS_JSON" | jq 'length')" -eq 0 ]; then
  echo "FAIL: KEEPER_MODELS is required (예: KEEPER_MODELS='gemini:gemini-2.5-flash')" >&2
  exit 1
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
player_keepers="$(printf "%s" "$party" | jq -c --arg tag "$KEEPER_TAG" '
  reduce .[] as $row ({}; . + {($row.actor_id): ("pk-" + $tag + "-" + $row.actor_id)})
')"
PLAYER_KEEPER_NAMES="$(printf "%s" "$player_keepers" | jq -r '.[]' | awk 'NF')"

echo "[bootstrap] keeper up/claim"
call_tool_checked 3200 "masc_keeper_up" "$(jq -cn --arg name "$DM_KEEPER" --arg room "$room_id" --argjson models "$KEEPER_MODELS_JSON" '{name:$name,goal:("TRPG room " + $room + " DM keeper"),instructions:"모든 응답은 한국어로 작성하세요.",models:$models,proactive_enabled:false,presence_keepalive:true}')" >/dev/null
while IFS='|' read -r actor_id keeper_name; do
  [ -z "$actor_id" ] && continue
  [ -z "$keeper_name" ] && continue
  call_tool_checked 3201 "masc_keeper_up" "$(jq -cn --arg name "$keeper_name" --arg room "$room_id" --arg actor "$actor_id" --argjson models "$KEEPER_MODELS_JSON" '{name:$name,goal:("TRPG room " + $room + "에서 " + $actor + " actor를 플레이하세요."),instructions:"모든 응답은 한국어로 작성하세요.",models:$models,proactive_enabled:false,presence_keepalive:true}')" >/dev/null
  call_tool_checked 3202 "trpg.actor.claim" "$(jq -cn --arg room "$room_id" --arg actor "$actor_id" --arg keeper "$keeper_name" '{room_id:$room,actor_id:$actor,keeper_name:$keeper}')" >/dev/null
done < <(printf "%s" "$player_keepers" | jq -r 'to_entries[] | "\(.key)|\(.value)"')

round_template="$(jq -cn --arg room "$room_id" --arg dm "$DM_KEEPER" --argjson player_keepers "$player_keepers" '{room_id:$room,dm_keeper:$dm,player_keepers:$player_keepers}')"

echo "[bootstrap] room_id=$room_id world_preset=$world_used dm_preset=$dm_used"

if [ "$RUN_ROUND" = "1" ]; then
  echo "[round] RUN_ROUND=1, executing $ROUNDS rounds"
  i=1
  while [ "$i" -le "$ROUNDS" ]; do
    echo "  - round $i"
    args_round="$(jq -cn --argjson t "$round_template" --argjson timeout "$ROUND_TIMEOUT_SEC" '{room_id:$t.room_id,dm_keeper:$t.dm_keeper,player_keepers:$t.player_keepers,phase:"round",timeout_sec:$timeout,require_claim:true}')"
    r_round="$(call_tool_checked $((4000 + i)) "trpg.round.run" "$args_round")"
    advanced="$(printf "%s" "$r_round" | payload | jq -r '.summary.advanced // empty')"
    if [ "$advanced" = "false" ]; then
      echo "FAIL: round $i did not advance"
      printf "%s\n" "$r_round"
      exit 1
    fi
    if [ -z "$advanced" ]; then
      turn_before="$(printf "%s" "$r_round" | payload | jq -r '.turn_before // 0')"
      turn_after="$(printf "%s" "$r_round" | payload | jq -r '.turn_after // 0')"
      if [ "${turn_after:-0}" -le "${turn_before:-0}" ]; then
        echo "FAIL: round $i turn did not increase (before=$turn_before after=$turn_after)"
        printf "%s\n" "$r_round"
        exit 1
      fi
    fi
    i=$((i + 1))
  done
fi

echo "[intervention] trpg.intervention.submit"
call_tool_checked 3500 "trpg.intervention.submit" "{\"room_id\":\"$room_id\",\"session_id\":\"$SESSION_ID\",\"intervention_type\":\"nudge\",\"payload\":{\"target\":\"trust\",\"delta\":0.1}}" >/dev/null

echo "[stream] trpg.stream.read"
r_stream="$(call_tool_checked 3600 "trpg.stream.read" "{\"room_id\":\"$room_id\"}")"
count="$(printf "%s" "$r_stream" | payload | jq -r '.count // 0')"

echo "PASS: trpg smoke (events=$count, room_id=$room_id, world_preset=$world_used, dm_preset=$dm_used, run_round=$RUN_ROUND)"
