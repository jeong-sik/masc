#!/usr/bin/env bash
set -euo pipefail

MCP_URL="${MCP_URL:-http://127.0.0.1:8935/mcp}"
BASE_PATH="${MASC_BASE_PATH:-$HOME/me}"
PROFILE="${VERIFIER_PROFILE:-abc_neutral}"
TWO_THIRDS="${TWO_THIRDS:-0.6666666666666666}"

run_case() {
  local policy="$1"
  local payload
  payload=$(cat <<JSON
{"jsonrpc":"2.0","id":902,"method":"tools/call","params":{"name":"masc_mitosis_handoff","arguments":{"context_ratio":0.3,"full_context":"mitosis verifier abc harness smoke","target_agent":"claude","async":true,"verify":true,"verification_policy":"$policy","verification_min_judges":3,"verification_pass_ratio":$TWO_THIRDS,"verification_min_agreement":$TWO_THIRDS,"verifier_profile":"$PROFILE","verifier_models":["invalid-a","invalid-b","invalid-c"]}}}
JSON
)

  local resp
  resp="$(curl -sS -m 15 -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d "$payload")"

  local saga_id
  saga_id="$(printf "%s" "$resp" | rg -o 'saga-[0-9-]+(-[0-9]+)?(\.json)?' | head -n1 | sed 's/\.json$//' || true)"
  if [ -z "$saga_id" ]; then
    echo "FAIL[$policy]: saga_id not found"
    printf "%s\n" "$resp"
    return 1
  fi

  local status_file="$BASE_PATH/.masc/mitosis_sagas/$saga_id.json"
  for _ in $(seq 1 30); do
    if [ -f "$status_file" ] && ! rg -q '"status": "running"' "$status_file"; then
      break
    fi
    sleep 1
  done

  if [ ! -f "$status_file" ]; then
    echo "FAIL[$policy]: saga status file not found: $status_file"
    return 1
  fi

  python3 - "$policy" "$status_file" <<'PY'
import json, sys
policy = sys.argv[1]
path = sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    doc = json.load(f)
pl = doc.get("payload", {})
ver = pl.get("verification", {})
rm = ver.get("research_metrics", {})
print(
    f"policy={policy} saga={doc.get('saga_id')} status={doc.get('status')} "
    f"gate={pl.get('verification_gate_passed')} overall={ver.get('overall')} "
    f"profile={ver.get('profile')} agreement={rm.get('inter_judge_agreement')} "
    f"evidence={rm.get('evidence_completeness')} pass_ratio={ver.get('pass_ratio')}"
)
PY
}

run_case advisory
run_case gate

echo "PASS: mitosis verifier A/B/C sweep harness"
