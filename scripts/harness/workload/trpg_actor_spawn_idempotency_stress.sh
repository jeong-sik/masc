#!/usr/bin/env bash
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
ROOM_ID="${ROOM_ID:-room-idem-stress-$(date +%s)}"
REQUESTS="${REQUESTS:-20}"
CONCURRENCY="${CONCURRENCY:-8}"
TIMEOUT_SEC="${TIMEOUT_SEC:-5}"
IDEMPOTENCY_KEY="${IDEMPOTENCY_KEY:-spawn-idem-stress-$(date +%s)}"

TMP_DIR="$(mktemp -d /tmp/trpg-spawn-idem-stress.XXXXXX)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

PAYLOAD="$(jq -cn \
  --arg room "$ROOM_ID" \
  '{room_id:$room,name:"Stress Echo",role:"player",max_hp:22,stats:{dex:13,luck:7}}')"

export BASE_URL IDEMPOTENCY_KEY PAYLOAD TIMEOUT_SEC TMP_DIR

seq 1 "$REQUESTS" | xargs -I{} -P "$CONCURRENCY" bash -c '
  idx="$1"
  body_file="$TMP_DIR/body.$idx.json"
  head_file="$TMP_DIR/head.$idx.txt"
  if ! curl -sS --http1.1 --max-time "$TIMEOUT_SEC" \
    -X POST "$BASE_URL/api/v1/trpg/actors/spawn" \
    -H "Content-Type: application/json" \
    -H "Idempotency-Key: $IDEMPOTENCY_KEY" \
    --data "$PAYLOAD" \
    -o "$body_file" \
    -D "$head_file"; then
    echo "curl_failed $idx" > "$TMP_DIR/fail.$idx.txt"
  fi
' _ {}

if ls "$TMP_DIR"/fail.*.txt >/dev/null 2>&1; then
  echo "FAIL: at least one curl call failed" >&2
  cat "$TMP_DIR"/fail.*.txt >&2 || true
  exit 1
fi

status_ok=0
status_fail=0
for head in "$TMP_DIR"/head.*.txt; do
  status="$(awk '/^HTTP\// {code=$2} END {print code+0}' "$head")"
  if [ "$status" -eq 201 ]; then
    status_ok=$((status_ok + 1))
  else
    status_fail=$((status_fail + 1))
  fi
done

actor_ids_file="$TMP_DIR/actor_ids.txt"
for body in "$TMP_DIR"/body.*.json; do
  jq -r '.actor_id // empty' "$body"
done | sed '/^$/d' > "$actor_ids_file"

unique_actor_ids="$(sort -u "$actor_ids_file" | wc -l | tr -d ' ')"

echo "requests=$REQUESTS ok=$status_ok fail=$status_fail unique_actor_ids=$unique_actor_ids room=$ROOM_ID key=$IDEMPOTENCY_KEY"

if [ "$status_fail" -ne 0 ]; then
  echo "FAIL: non-201 responses detected" >&2
  exit 1
fi

if [ "$unique_actor_ids" -ne 1 ]; then
  echo "FAIL: expected exactly one unique actor_id for same key" >&2
  sort -u "$actor_ids_file" >&2
  exit 1
fi

MISMATCH_PAYLOAD="$(jq -cn \
  --arg room "$ROOM_ID" \
  '{room_id:$room,name:"Different Payload",role:"player"}')"
mismatch_body="$TMP_DIR/mismatch_body.json"
mismatch_head="$TMP_DIR/mismatch_head.txt"
curl -sS --http1.1 --max-time "$TIMEOUT_SEC" \
  -X POST "$BASE_URL/api/v1/trpg/actors/spawn" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: $IDEMPOTENCY_KEY" \
  --data "$MISMATCH_PAYLOAD" \
  -o "$mismatch_body" \
  -D "$mismatch_head"

mismatch_status="$(awk '/^HTTP\// {code=$2} END {print code+0}' "$mismatch_head")"
if [ "$mismatch_status" -ne 400 ]; then
  echo "FAIL: expected mismatch status 400, got $mismatch_status" >&2
  cat "$mismatch_body" >&2 || true
  exit 1
fi

if ! grep -q "idempotency_payload_mismatch" "$mismatch_body"; then
  echo "FAIL: mismatch response missing idempotency_payload_mismatch marker" >&2
  cat "$mismatch_body" >&2 || true
  exit 1
fi

echo "PASS: trpg actor spawn idempotency stress"
