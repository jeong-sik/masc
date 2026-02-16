#!/usr/bin/env bash
set -euo pipefail

MCP_URL="${MCP_URL:-http://127.0.0.1:8935/mcp}"
BASE_PATH="${MASC_BASE_PATH:-$HOME/me}"

payload='{"jsonrpc":"2.0","id":901,"method":"tools/call","params":{"name":"masc_mitosis_handoff","arguments":{"context_ratio":0.3,"full_context":"mitosis verifier harness smoke","target_agent":"claude","async":true,"verify":true,"verification_policy":"gate","verification_min_judges":1,"verification_pass_ratio":1.0,"verifier_models":["invalid-model-spec"],"verifier_perspectives":["risk_guardrail"]}}}'

resp="$(curl -sS -m 15 -X POST "$MCP_URL" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d "$payload")"

saga_id="$(printf "%s" "$resp" | rg -o 'saga-[0-9-]+(-[0-9]+)?(\.json)?' | head -n1 | sed 's/\.json$//' || true)"
if [ -z "$saga_id" ]; then
  echo "FAIL: saga_id not found in response"
  printf "%s\n" "$resp"
  exit 1
fi

status_file="$BASE_PATH/.masc/mitosis_sagas/$saga_id.json"

for _ in $(seq 1 30); do
  if [ -f "$status_file" ] && ! rg -q '"status": "running"' "$status_file"; then
    break
  fi
  sleep 1
done

if [ ! -f "$status_file" ]; then
  echo "FAIL: saga status file not found: $status_file"
  exit 1
fi

echo "saga_id=$saga_id"
cat "$status_file"

if ! rg -q '"status": "failed"' "$status_file"; then
  echo "FAIL: expected saga status failed"
  exit 1
fi

if ! rg -q '"verification_gate_passed": false' "$status_file"; then
  echo "FAIL: expected verification_gate_passed=false"
  exit 1
fi

echo "PASS: mitosis verifier gate harness"
