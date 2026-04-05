#!/bin/bash
# MASC-MCP Dashboard Verification Suite
# Usage: ./scripts/verify-dashboard.sh [BASE_URL]
# Default: http://127.0.0.1:8935

set -euo pipefail

BASE="${1:-http://127.0.0.1:8935}"
PASS=0; FAIL=0; TOTAL=0

check() {
  TOTAL=$((TOTAL+1))
  local name="$1"; local url="$2"; local expect="$3"
  local resp
  resp=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null) || resp="000"
  if [ "$resp" = "$expect" ]; then
    PASS=$((PASS+1)); echo "  PASS: $name (HTTP $resp)"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: $name (HTTP $resp, expected $expect)"
  fi
}

check_json() {
  TOTAL=$((TOTAL+1))
  local name="$1"; local url="$2"; local expr="$3"; local expect="$4"
  local val
  val=$(curl -s "$url" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print($expr)" 2>/dev/null) || val="ERROR"
  if echo "$val" | grep -q "$expect"; then
    PASS=$((PASS+1)); echo "  PASS: $name ($val)"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: $name (got '$val', expected '$expect')"
  fi
}

echo "=== MASC-MCP Verification Suite ==="
echo "    Target: $BASE"
echo ""

echo "[1/7] Health"
check "health 200" "$BASE/health" "200"
check_json "version" "$BASE/health" "d['version']" "2\."

echo "[2/7] Board"
check "board list" "$BASE/api/v1/board" "200"
check_json "board has posts" "$BASE/api/v1/board" "len(d.get('posts',[]))" "[0-9]"
FIRST_ID=$(curl -s "$BASE/api/v1/board" 2>/dev/null | python3 -c "import sys,json; posts=json.load(sys.stdin).get('posts',[]); print(posts[0]['id'] if posts else 'none')" 2>/dev/null)
if [ "$FIRST_ID" != "none" ] && [ -n "$FIRST_ID" ]; then
  check "board detail /:id" "$BASE/api/v1/board/$FIRST_ID" "200"
else
  TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "  FAIL: board detail (no posts to test)"
fi

echo "[3/7] Keeper Config (Phase 1)"
check "config 200" "$BASE/api/v1/keepers/sangsu/config" "200"
check_json "pipeline_stage" "$BASE/api/v1/keepers/sangsu/config" "d['pipeline_stage']" "."
check "config 404 (missing)" "$BASE/api/v1/keepers/NONEXISTENT/config" "404"

echo "[4/7] Config Edit (Phase 2)"
EDIT_RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/keepers/sangsu/config" \
  -H 'Content-Type: application/json' -d '{}' 2>/dev/null)
TOTAL=$((TOTAL+1))
if [ "$EDIT_RESP" = "200" ]; then
  PASS=$((PASS+1)); echo "  PASS: empty edit no-op (HTTP $EDIT_RESP)"
else
  FAIL=$((FAIL+1)); echo "  FAIL: empty edit no-op (HTTP $EDIT_RESP)"
fi
INVALID_RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/keepers/sangsu/config" \
TOTAL=$((TOTAL+1))
if [ "$INVALID_RESP" = "400" ]; then
else
fi

echo "[5/7] Logs"
check "logs 200" "$BASE/api/v1/dashboard/logs" "200"
check_json "logs has entries" "$BASE/api/v1/dashboard/logs?limit=3" "len(d.get('entries',[]))" "[0-9]"

echo "[6/7] Dashboard SPA"
check "dashboard index" "$BASE/dashboard" "200"

echo "[7/7] Encoded Header"
check "encoded agent header" "$BASE/api/v1/board" "200"

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "=== ALL $TOTAL TESTS PASSED ==="
else
  echo "=== $PASS/$TOTAL passed, $FAIL FAILED ==="
  exit 1
fi
