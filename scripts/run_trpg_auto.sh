#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOAK_SCRIPT="$SCRIPT_DIR/harness/workload/trpg_grimland_smoke.sh"

MCP_URL="${MCP_URL:-http://127.0.0.1:8935/mcp}"
DURATION_SEC="${DURATION_SEC:-10800}"   # 3h default
ROUNDS_PER_SESSION="${ROUNDS_PER_SESSION:-2}"
SLEEP_BETWEEN_SEC="${SLEEP_BETWEEN_SEC:-2}"
ROUND_TIMEOUT_SEC="${ROUND_TIMEOUT_SEC:-20}"
KEEPER_MODELS="${KEEPER_MODELS:-}"
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/../logs/trpg-auto-$(date +%Y%m%d-%H%M%S).log}"

mkdir -p "$(dirname "$LOG_FILE")"

extract_payload() {
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

call_tool_raw() {
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

read_preset_catalog() {
  local raw
  raw="$(call_tool_raw 1201 "trpg.preset.list" '{"include_characters":false,"include_skills":false}')"
  printf "%s" "$raw" | extract_payload 2>/dev/null || printf "{}"
}

echo "[trpg-auto] start duration=${DURATION_SEC}s rounds_per_session=${ROUNDS_PER_SESSION}" | tee -a "$LOG_FILE"
echo "[trpg-auto] mcp_url=${MCP_URL}" | tee -a "$LOG_FILE"
if [ -z "$(printf "%s" "$KEEPER_MODELS" | tr -d '[:space:]')" ]; then
  echo "[trpg-auto] FAIL: KEEPER_MODELS is required (예: KEEPER_MODELS='gemini:gemini-2.5-flash')" | tee -a "$LOG_FILE"
  exit 1
fi
echo "[trpg-auto] keeper_models=${KEEPER_MODELS}" | tee -a "$LOG_FILE"

catalog_json="$(read_preset_catalog)"
WORLD_PRESETS=()
while IFS= read -r row; do
  WORLD_PRESETS+=("$row")
done < <(printf "%s" "$catalog_json" | jq -r '.world_presets[]? | (.id // .preset_id // empty)' | awk 'NF')
DM_PRESETS=()
while IFS= read -r row; do
  DM_PRESETS+=("$row")
done < <(printf "%s" "$catalog_json" | jq -r '.dm_presets[]? | (.id // .preset_id // empty)' | awk 'NF')
echo "[trpg-auto] catalog world=${#WORLD_PRESETS[@]} dm=${#DM_PRESETS[@]}" | tee -a "$LOG_FILE"

world_hist="$(mktemp -t trpg-auto-world.XXXXXX)"
dm_hist="$(mktemp -t trpg-auto-dm.XXXXXX)"
combo_hist="$(mktemp -t trpg-auto-combo.XXXXXX)"
trap 'rm -f "$world_hist" "$dm_hist" "$combo_hist"' EXIT

end_ts=$(( $(date +%s) + DURATION_SEC ))
ok_count=0
fail_count=0
iter=0

while [ "$(date +%s)" -lt "$end_ts" ]; do
  iter=$((iter + 1))
  session_id="auto-soak-$(date +%s)-${iter}"
  keeper_tag="soak-${iter}"
  world_preset_id=""
  dm_preset_id=""
  party_size=$((3 + ((iter - 1) % 3)))   # 3,4,5 순환
  pool_size=$((party_size + 2))
  combo_idx=$((iter - 1))
  if [ "${#WORLD_PRESETS[@]}" -gt 0 ] && [ "${#DM_PRESETS[@]}" -gt 0 ]; then
    world_idx=$(( combo_idx % ${#WORLD_PRESETS[@]} ))
    dm_idx=$(( (combo_idx / ${#WORLD_PRESETS[@]}) % ${#DM_PRESETS[@]} ))
    world_preset_id="${WORLD_PRESETS[$world_idx]}"
    dm_preset_id="${DM_PRESETS[$dm_idx]}"
  else
    if [ "${#WORLD_PRESETS[@]}" -gt 0 ]; then
      world_preset_id="${WORLD_PRESETS[$(( combo_idx % ${#WORLD_PRESETS[@]} ))]}"
    fi
    if [ "${#DM_PRESETS[@]}" -gt 0 ]; then
      dm_preset_id="${DM_PRESETS[$(( combo_idx % ${#DM_PRESETS[@]} ))]}"
    fi
  fi
  echo "[trpg-auto] iter=${iter} session_id=${session_id} world=${world_preset_id:-auto} dm=${dm_preset_id:-auto} party=${party_size} pool=${pool_size} start" | tee -a "$LOG_FILE"
  printf "%s\n" "${world_preset_id:-auto}" >>"$world_hist"
  printf "%s\n" "${dm_preset_id:-auto}" >>"$dm_hist"
  printf "%s|%s\n" "${world_preset_id:-auto}" "${dm_preset_id:-auto}" >>"$combo_hist"

  if MCP_URL="$MCP_URL" \
    SESSION_ID="$session_id" \
    RUN_ROUND=1 \
    ROUNDS="$ROUNDS_PER_SESSION" \
    WORLD_PRESET_ID="$world_preset_id" \
    DM_PRESET_ID="$dm_preset_id" \
    KEEPER_TAG="$keeper_tag" \
    KEEPER_MODELS="$KEEPER_MODELS" \
    ROUND_TIMEOUT_SEC="$ROUND_TIMEOUT_SEC" \
    PARTY_SIZE="$party_size" \
    POOL_SIZE="$pool_size" \
    "$SOAK_SCRIPT" >>"$LOG_FILE" 2>&1; then
    ok_count=$((ok_count + 1))
    echo "[trpg-auto] iter=${iter} result=ok ok=${ok_count} fail=${fail_count}" | tee -a "$LOG_FILE"
  else
    fail_count=$((fail_count + 1))
    echo "[trpg-auto] iter=${iter} result=fail ok=${ok_count} fail=${fail_count}" | tee -a "$LOG_FILE"
  fi

  sleep "$SLEEP_BETWEEN_SEC"
done

echo "[trpg-auto] done iter=${iter} ok=${ok_count} fail=${fail_count}" | tee -a "$LOG_FILE"
echo "[trpg-auto] world distribution:" | tee -a "$LOG_FILE"
sort "$world_hist" | uniq -c | sort -nr | head -n 10 | tee -a "$LOG_FILE"
echo "[trpg-auto] dm distribution:" | tee -a "$LOG_FILE"
sort "$dm_hist" | uniq -c | sort -nr | head -n 10 | tee -a "$LOG_FILE"
echo "[trpg-auto] world|dm distribution:" | tee -a "$LOG_FILE"
sort "$combo_hist" | uniq -c | sort -nr | head -n 10 | tee -a "$LOG_FILE"
