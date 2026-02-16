#!/bin/bash
# Lodge Worker — 로컬에서 Heartbeat 작업 처리
# MASC 서버에서 작업 받아서 로컬 LLM으로 처리

set -e

MASC_URL="${MASC_URL:-https://masc.crying.pictures}"
LLM_MCP_URL="${LLM_MCP_URL:-http://localhost:8932}"
WORKER_NAME="${WORKER_NAME:-lodge-worker-$(hostname -s)}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "🔧 Lodge Worker starting..."
log "   MASC: $MASC_URL"
log "   LLM:  $LLM_MCP_URL"
log "   Name: $WORKER_NAME"

# 1. MASC에 Worker 등록
log "📡 Joining MASC..."
curl -s "$MASC_URL/mcp" \
  -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"masc_join\",\"arguments\":{\"agent_name\":\"$WORKER_NAME\"}},\"id\":1}" \
  | jq -r '.result.content[0].text // .error.message' | head -3

# 2. Heartbeat 이벤트 구독
log "🔔 Subscribing to heartbeat events..."
SUBSCRIPTION=$(curl -s "$MASC_URL/mcp" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"masc_a2a_subscribe","arguments":{"events":["heartbeat_task","broadcast"]}},"id":2}' \
  | jq -r '.result.content[0].text' | grep -o 'sub-[a-f0-9-]*' || echo "")

if [ -z "$SUBSCRIPTION" ]; then
  log "⚠️  Subscription failed, using poll mode"
fi

log "✅ Worker ready! Polling every ${POLL_INTERVAL}s..."

# 3. 메인 루프 — 작업 폴링 & 처리
while true; do
  # Poll for events
  EVENTS=$(curl -s "$MASC_URL/mcp" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"masc_poll_events\",\"arguments\":{\"subscription_id\":\"$SUBSCRIPTION\"}},\"id\":3}" \
    2>/dev/null | jq -r '.result.content[0].text // ""')

  # Check for heartbeat tasks
  if echo "$EVENTS" | grep -q "heartbeat_task"; then
    log "💓 Heartbeat task received!"

    # Extract agent and prompt from event
    AGENT=$(echo "$EVENTS" | grep -o '"agent":"[^"]*"' | head -1 | cut -d'"' -f4)
    PROMPT=$(echo "$EVENTS" | grep -o '"prompt":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ -n "$AGENT" ] && [ -n "$PROMPT" ]; then
      log "🤖 Processing for agent: $AGENT"

      # Call local LLM via llm-mcp
      RESPONSE=$(curl -s "$LLM_MCP_URL/mcp" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"glm\",\"arguments\":{\"prompt\":\"$PROMPT\"}},\"id\":10}" \
        2>/dev/null | jq -r '.result.content[0].text // "LLM call failed"' | head -500)

      # Broadcast result
      log "📤 Broadcasting response..."
      curl -s "$MASC_URL/mcp" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"masc_broadcast\",\"arguments\":{\"agent_name\":\"$WORKER_NAME\",\"message\":\"[$AGENT] $RESPONSE\"}},\"id\":4}" \
        >/dev/null

      log "✅ Done processing $AGENT"
    fi
  fi

  sleep "$POLL_INTERVAL"
done
