#!/usr/bin/env bash
set -euo pipefail

SESSION_ID="${SESSION_ID:-harness-trpg-session-$(date +%s)-$$}"
ROOM_ID="${ROOM_ID:-}"
CURL_RETRY_COUNT="${CURL_RETRY_COUNT:-12}"
export CURL_RETRY_COUNT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_FRAMEWORK_SH="${SCRIPT_DIR}/../lib/test_framework.sh"
if [ ! -f "$TEST_FRAMEWORK_SH" ]; then
  TEST_FRAMEWORK_SH="${SCRIPT_DIR}/../../../scripts/harness/lib/test_framework.sh"
fi
source "$TEST_FRAMEWORK_SH"

echo "[1/6] trpg.preset.list"
r1="$(call_tool 2001 "trpg.preset.list" "{}")"
if ! printf "%s" "$r1" | extract_payload | jq -e '.dm_presets | length >= 1' >/dev/null; then
  echo "FAIL: trpg.preset.list should return dm_presets"
  printf "%s\n" "$r1"
  exit 1
fi

echo "[2/6] trpg.pool.generate"
r2="$(call_tool 2002 "trpg.pool.generate" "{\"session_id\":\"$SESSION_ID\",\"pool_size\":6,\"party_size\":4,\"seed\":11}")"
pool_json="$(printf "%s" "$r2" | extract_payload | jq -c '.pool // []')"
suggested_json="$(printf "%s" "$r2" | extract_payload | jq -c '.suggested_party_ids // []')"
if [ "$(printf "%s" "$pool_json" | jq -r 'length')" -lt 4 ]; then
  echo "FAIL: pool_size too small"
  printf "%s\n" "$r2"
  exit 1
fi
if [ "$(printf "%s" "$suggested_json" | jq -r 'length')" -ne 4 ]; then
  echo "FAIL: suggested_party_ids should contain 4 players"
  printf "%s\n" "$r2"
  exit 1
fi

echo "[3/6] trpg.party.select"
args_party="$(jq -cn --arg sid "$SESSION_ID" --argjson pool "$pool_json" --argjson ids "$suggested_json" '{session_id:$sid,pool:$pool,selected_player_ids:$ids}')"
r3="$(call_tool 2003 "trpg.party.select" "$args_party")"
party_json="$(printf "%s" "$r3" | extract_payload | jq -c '.party // []')"
if [ "$(printf "%s" "$party_json" | jq -r 'length')" -ne 4 ]; then
  echo "FAIL: party.select should return exactly 4 members"
  printf "%s\n" "$r3"
  exit 1
fi

echo "[4/6] trpg.session.start"
args_start="$(jq -cn --arg sid "$SESSION_ID" --arg room "$ROOM_ID" --argjson party "$party_json" '
  if $room == "" then
    {session_id:$sid,party:$party,phase:"briefing"}
  else
    {session_id:$sid,room_id:$room,party:$party,phase:"briefing",force:true}
  end
')"
r4="$(call_tool 2004 "trpg.session.start" "$args_start")"
room_id="$(printf "%s" "$r4" | extract_payload | jq -r '.room_id // empty')"
if [ -z "$room_id" ]; then
  echo "FAIL: trpg.session.start should return room_id"
  printf "%s\n" "$r4"
  exit 1
fi
if ! printf "%s" "$r4" | extract_payload | jq -e '.events | map(.type) | index("session.started") != null' >/dev/null; then
  echo "FAIL: trpg.session.start should emit session.started"
  printf "%s\n" "$r4"
  exit 1
fi

echo "[5/6] trpg.intervention.submit"
r5="$(call_tool 2005 "trpg.intervention.submit" "{\"room_id\":\"$room_id\",\"session_id\":\"$SESSION_ID\",\"intervention_type\":\"nudge\",\"reason\":\"contract-harness\",\"payload\":{\"delta\":0.1}}")"
if [ "$(printf "%s" "$r5" | extract_payload | jq -r '.status // empty')" != "pending" ]; then
  echo "FAIL: trpg.intervention.submit should return pending"
  printf "%s\n" "$r5"
  exit 1
fi

echo "[6/6] trpg.stream.read (submitted intervention visible)"
r6="$(call_tool 2006 "trpg.stream.read" "{\"room_id\":\"$room_id\",\"event_type\":\"intervention.submitted\"}")"
if ! printf "%s" "$r6" | extract_payload | jq -e '.count >= 1' >/dev/null; then
  echo "FAIL: trpg.stream.read should include intervention.submitted"
  printf "%s\n" "$r6"
  exit 1
fi

echo "PASS: TRPG session contract harness"
