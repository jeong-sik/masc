#!/usr/bin/env bash
set -euo pipefail

MCP_URL="${MCP_URL:-http://127.0.0.1:8935/mcp}"
SESSION_ID="${SESSION_ID:-smoke-grimland-$(date +%s)}"
ROOM_ID="${ROOM_ID:-}"
ROUNDS="${ROUNDS:-2}"
RUN_ROUND="${RUN_ROUND:-0}"  # 0: bootstrap only, 1: include trpg.round.run

call_tool() {
  local id="$1"
  local name="$2"
  local args_json="$3"
  local raw
  local sse_data
  raw="$(curl -sS -m 30 -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":\"tools/call\",\"params\":{\"name\":\"$name\",\"arguments\":$args_json}}")"
  sse_data="$(printf "%s" "$raw" | sed -n 's/^data: //p' | tail -n1)"
  if [ -n "$sse_data" ]; then
    printf "%s" "$sse_data"
  else
    printf "%s" "$raw"
  fi
}

payload() {
  jq -c 'try (.result.content[0].text | fromjson | .payload) catch empty'
}

echo "[bootstrap] trpg.pool.generate"
r_pool="$(call_tool 3001 "trpg.pool.generate" "{\"session_id\":\"$SESSION_ID\",\"world_preset_id\":\"grimland-chronicle\",\"pool_size\":6,\"party_size\":4}")"
pool="$(printf "%s" "$r_pool" | payload | jq -c '.pool')"
suggested="$(printf "%s" "$r_pool" | payload | jq -c '.suggested_party_ids')"

echo "[bootstrap] trpg.party.select"
args_party="$(jq -cn --arg sid "$SESSION_ID" --argjson pool "$pool" --argjson ids "$suggested" '{session_id:$sid,pool:$pool,selected_player_ids:$ids}')"
r_party="$(call_tool 3002 "trpg.party.select" "$args_party")"
party="$(printf "%s" "$r_party" | payload | jq -c '.party')"

echo "[bootstrap] trpg.session.start"
args_start="$(jq -cn --arg sid "$SESSION_ID" --arg room "$ROOM_ID" --argjson party "$party" '
  if $room == "" then
    {session_id:$sid,party:$party,phase:"briefing"}
  else
    {session_id:$sid,room_id:$room,party:$party,phase:"briefing"}
  end
')"
r_start="$(call_tool 3003 "trpg.session.start" "$args_start")"
room_id="$(printf "%s" "$r_start" | payload | jq -r '.room_id')"
round_template="$(printf "%s" "$r_start" | payload | jq -c '.round_run_template')"

echo "[bootstrap] room_id=$room_id"

if [ "$RUN_ROUND" = "1" ]; then
  echo "[round] RUN_ROUND=1, executing $ROUNDS rounds"
  i=1
  while [ "$i" -le "$ROUNDS" ]; do
    echo "  - round $i"
    args_round="$(jq -cn --argjson t "$round_template" '{room_id:$t.room_id,dm_keeper:$t.dm_keeper,player_keepers:$t.player_keepers,phase:"round",timeout_sec:2.0}')"
    call_tool $((4000 + i)) "trpg.round.run" "$args_round" >/dev/null
    i=$((i + 1))
  done
fi

echo "[intervention] trpg.intervention.submit"
call_tool 3500 "trpg.intervention.submit" "{\"room_id\":\"$room_id\",\"session_id\":\"$SESSION_ID\",\"intervention_type\":\"nudge\",\"payload\":{\"target\":\"trust\",\"delta\":0.1}}" >/dev/null

echo "[stream] trpg.stream.read"
r_stream="$(call_tool 3600 "trpg.stream.read" "{\"room_id\":\"$room_id\"}")"
count="$(printf "%s" "$r_stream" | payload | jq -r '.count // 0')"

echo "PASS: grimland smoke (events=$count, room_id=$room_id, run_round=$RUN_ROUND)"
