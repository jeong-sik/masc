#!/usr/bin/env bash
set -euo pipefail

MCP_URL="${MCP_URL:-http://127.0.0.1:8935/mcp}"
BASE_PATH="${MASC_BASE_PATH:-$HOME/me}"
RUNS="${RUNS:-10}"
CONTEXT_RATIO="${CONTEXT_RATIO:-0.85}"

# Comparison A (baseline)
LABEL_A="${LABEL_A:-baseline}"
CONT_MIN_A="${CONT_MIN_A:-0.34}"
RECHECK_A="${RECHECK_A:-0}"

# Comparison B (stricter continuity + recheck)
LABEL_B="${LABEL_B:-strict}"
CONT_MIN_B="${CONT_MIN_B:-0.50}"
RECHECK_B="${RECHECK_B:-1}"

MIN_JUDGES="${MIN_JUDGES:-3}"
PASS_RATIO="${PASS_RATIO:-0.6666666666666666}"
MIN_AGREEMENT="${MIN_AGREEMENT:-0.6666666666666666}"
JUDGE_TIMEOUT_SEC="${JUDGE_TIMEOUT_SEC:-60}"
SAGA_TIMEOUT_SEC="${SAGA_TIMEOUT_SEC:-180}"
PROFILE="${VERIFIER_PROFILE:-abc_neutral}"
MODELS_JSON="${MODELS_JSON:-[\"gemini:gemini-2.5-flash\",\"glm:glm-4.7\",\"gemini:gemini-2.5-flash\"]}"

run_case() {
  local label="$1"
  local continuity_min="$2"
  local recheck_count="$3"
  local payload resp saga_id status_file

  payload=$(cat <<JSON
{"jsonrpc":"2.0","id":2101,"method":"tools/call","params":{"name":"masc_mitosis_handoff","arguments":{"context_ratio":$CONTEXT_RATIO,"full_context":"Goal: preserve continuity across generations\nCurrent Task: compare continuity threshold and recheck settings\nRecent turn: run continuity-recheck comparison harness","target_agent":"claude","async":true,"verify":true,"verification_policy":"gate","verification_min_judges":$MIN_JUDGES,"verification_pass_ratio":$PASS_RATIO,"verification_min_agreement":$MIN_AGREEMENT,"verification_judge_timeout_sec":$JUDGE_TIMEOUT_SEC,"verification_saga_timeout_sec":$SAGA_TIMEOUT_SEC,"verification_recheck_count":$recheck_count,"continuity_retention_min":$continuity_min,"verifier_profile":"$PROFILE","verifier_models":$MODELS_JSON}}}
JSON
)

  resp="$(curl -sS -m 60 -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d "$payload")"

  saga_id="$(printf "%s" "$resp" | rg -o 'saga-[0-9-]+(-[0-9]+)?(\.json)?' | head -n1 | sed 's/\.json$//' || true)"
  if [ -z "$saga_id" ]; then
    echo "label=$label saga=NA status=error gate=False pass_ratio=None agreement=None evidence=None continuity=None recheck_stability=None memory_decision=None next_action=None"
    return
  fi

  status_file="$BASE_PATH/.masc/mitosis_sagas/$saga_id.json"
  for _ in $(seq 1 240); do
    if [ -f "$status_file" ] && ! rg -q '"status": "running"' "$status_file"; then
      break
    fi
    sleep 1
  done

  python3 - "$label" "$status_file" <<'PY'
import json, sys
label = sys.argv[1]
path = sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as f:
        doc = json.load(f)
except Exception:
    print(f"label={label} saga=NA status=error gate=False pass_ratio=None agreement=None evidence=None continuity=None recheck_stability=None memory_decision=None next_action=None")
    raise SystemExit(0)

payload = doc.get("payload", {})
verification = payload.get("verification", {})
metrics = verification.get("research_metrics", {})
memory = verification.get("memory_promotion", {})
plan = verification.get("next_turn_plan", {})

print(
    f"label={label} saga={doc.get('saga_id')} status={doc.get('status')} "
    f"gate={payload.get('verification_gate_passed')} "
    f"pass_ratio={verification.get('pass_ratio')} "
    f"agreement={metrics.get('inter_judge_agreement')} "
    f"evidence={metrics.get('evidence_completeness')} "
    f"continuity={metrics.get('continuity_retention')} "
    f"recheck_stability={metrics.get('judge_recheck_stability')} "
    f"memory_decision={memory.get('decision')} "
    f"next_action={plan.get('action')}"
)
PY
}

LOG_FILE="/tmp/mitosis-continuity-recheck-cmp-$(date +%s).log"
for _ in $(seq 1 "$RUNS"); do
  run_case "$LABEL_A" "$CONT_MIN_A" "$RECHECK_A" | tee -a "$LOG_FILE"
  run_case "$LABEL_B" "$CONT_MIN_B" "$RECHECK_B" | tee -a "$LOG_FILE"
done

python3 - "$LOG_FILE" "$LABEL_A" "$LABEL_B" <<'PY'
import statistics
import sys

path = sys.argv[1]
labels = [sys.argv[2], sys.argv[3]]

rows = []
for line in open(path, encoding="utf-8"):
    line = line.strip()
    if not line.startswith("label="):
        continue
    parts = {}
    for tok in line.split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            parts[k] = v
    rows.append({
        "label": parts.get("label"),
        "status": parts.get("status"),
        "gate": None if parts.get("gate") in (None, "None") else parts["gate"].lower() == "true",
        "pass_ratio": None if parts.get("pass_ratio") in (None, "None") else float(parts["pass_ratio"]),
        "agreement": None if parts.get("agreement") in (None, "None") else float(parts["agreement"]),
        "evidence": None if parts.get("evidence") in (None, "None") else float(parts["evidence"]),
        "continuity": None if parts.get("continuity") in (None, "None") else float(parts["continuity"]),
        "recheck_stability": None if parts.get("recheck_stability") in (None, "None") else float(parts["recheck_stability"]),
        "memory_decision": parts.get("memory_decision"),
        "next_action": parts.get("next_action"),
    })

for label in labels:
    group = [r for r in rows if r["label"] == label]
    if not group:
        continue
    gate_true = sum(1 for r in group if r["gate"] is True)
    completed = sum(1 for r in group if r["status"] == "completed")
    failed = sum(1 for r in group if r["status"] == "failed")
    running = sum(1 for r in group if r["status"] == "running")
    errors = sum(1 for r in group if r["status"] == "error")
    promoted = sum(1 for r in group if r["memory_decision"] == "promote")
    held = sum(1 for r in group if r["memory_decision"] == "hold")
    pass_ratios = [r["pass_ratio"] for r in group if isinstance(r["pass_ratio"], (int, float))]
    agreements = [r["agreement"] for r in group if isinstance(r["agreement"], (int, float))]
    evidences = [r["evidence"] for r in group if isinstance(r["evidence"], (int, float))]
    continuities = [r["continuity"] for r in group if isinstance(r["continuity"], (int, float))]
    stabilities = [r["recheck_stability"] for r in group if isinstance(r["recheck_stability"], (int, float))]
    print(
        f"SUMMARY label={label} runs={len(group)} gate_true={gate_true} gate_rate={gate_true/len(group):.4f} "
        f"completed={completed} failed={failed} running={running} error={errors} "
        f"promote={promoted} hold={held} "
        f"pass_ratio_mean={(statistics.mean(pass_ratios) if pass_ratios else 0.0):.4f} "
        f"agreement_mean={(statistics.mean(agreements) if agreements else 0.0):.4f} "
        f"evidence_mean={(statistics.mean(evidences) if evidences else 0.0):.4f} "
        f"continuity_mean={(statistics.mean(continuities) if continuities else 0.0):.4f} "
        f"recheck_stability_mean={(statistics.mean(stabilities) if stabilities else 0.0):.4f}"
    )

print(f"RUN_LOG={path}")
PY
