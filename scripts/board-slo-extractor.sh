#!/usr/bin/env bash
# board-slo-extractor.sh — Board convergence SLO snapshot (PR-1).
#
# Read-only. Runtime 무변경. basepath SSOT 준수:
#   MASC_BASE_PATH env 우선 → config_dir_resolver fallback → hard fail.
# 절대 $HOME 또는 ~/me 하드코딩 금지.
#
# Output: 13-row SLO table per Goal goal-board-live-issue-convergence-20260519.
# Modes: --json (default), --table (human render via jq).

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- basepath SSOT resolution -------------------------------------------------
resolve_basepath() {
  if [[ -n "${MASC_BASE_PATH:-}" ]]; then
    printf '%s' "$MASC_BASE_PATH"
    return 0
  fi
  # Fallback: resolver via env_config_core normalization mirror.
  # config_dir_resolver SSOT: MASC_CONFIG_DIR > $MASC_BASE_PATH/.masc/config > missing.
  # When neither env is set, refuse to guess — hard fail with directive.
  echo "ERROR: MASC_BASE_PATH unset. Set it explicitly (current env: \"$HOME\" is not a default)." >&2
  echo "       Hint: export MASC_BASE_PATH=\"\$HOME/me\"   # current developer env" >&2
  return 2
}

readonly BASE_PATH="$(resolve_basepath)"
readonly MASC_DIR="$BASE_PATH/.masc"
readonly LOGS_DIR="$MASC_DIR/logs"
readonly TASKS_FILE="$MASC_DIR/tasks/backlog.json"
readonly POSTS_FILE="$MASC_DIR/board_posts.jsonl"
readonly COMMENTS_FILE="$MASC_DIR/board_comments.jsonl"
readonly TODAY="$(date -u +%Y-%m-%d)"
readonly LOG_TODAY="$LOGS_DIR/system_log_${TODAY}.jsonl"

WINDOW_HOURS=24
OUTPUT_MODE=json
DASHBOARD_HOST="http://127.0.0.1:8935"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --window-hours) WINDOW_HOURS="$2"; shift 2 ;;
    --table) OUTPUT_MODE=table; shift ;;
    --json) OUTPUT_MODE=json; shift ;;
    --dashboard-host) DASHBOARD_HOST="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

readonly WINDOW_SEC=$(( WINDOW_HOURS * 3600 ))

# --- metric primitives --------------------------------------------------------

m_open_backlog() {
  [[ -f "$TASKS_FILE" ]] || { echo "0"; return; }
  jq '[.tasks[]? | select(.status!="done" and .status!="cancelled")] | length' "$TASKS_FILE"
}

m_p1_open() {
  [[ -f "$TASKS_FILE" ]] || { echo "0"; return; }
  jq '[.tasks[]? | select(.status!="done" and .status!="cancelled" and .priority==1)] | length' "$TASKS_FILE"
}

m_pending_verification_gt_48h() {
  # Pending verification older than 48h. Source: tasks awaiting_verification with submitted_at.
  [[ -f "$TASKS_FILE" ]] || { echo "0"; return; }
  jq --argjson cutoff "$(( $(date +%s) - 172800 ))" \
     '[.tasks[]? | select(.status=="awaiting_verification" and (.verification_submitted_at // 0) < $cutoff)] | length' \
     "$TASKS_FILE"
}

m_posts_window() {
  [[ -f "$POSTS_FILE" ]] || { echo "0"; return; }
  jq -s --argjson w "$WINDOW_SEC" \
     '[.[] | select(.created_at >= (now - $w))] | length' "$POSTS_FILE"
}

m_comments_window() {
  [[ -f "$COMMENTS_FILE" ]] || { echo "0"; return; }
  jq -s --argjson w "$WINDOW_SEC" \
     '[.[] | select(.created_at >= (now - $w))] | length' "$COMMENTS_FILE"
}

m_high_churn_threads_48h() {
  [[ -f "$COMMENTS_FILE" ]] || { echo "0"; return; }
  jq -s '[.[] | select(.created_at >= (now - 172800))]
         | group_by(.post_id)
         | map(select(length >= 20)) | length' "$COMMENTS_FILE"
}

m_warn_error_window() {
  [[ -f "$LOG_TODAY" ]] || { echo "0"; return; }
  # level filter — accept WARN / ERROR / WARNING uppercase.
  rg --count -e '"level":"(WARN|ERROR|WARNING)"' "$LOG_TODAY" || true
}

m_tool_call_success_pct() {
  # WORKAROUND: analyze-tool-call-quality.sh has no --json mode yet.
  # 근본 해결: 별도 PR로 두 analyze-* scripts에 --json 추가 후 단일 contract 호출로 교체.
  local script="$REPO_ROOT/scripts/analyze-tool-call-quality.sh"
  [[ -x "$script" ]] || { echo "null"; return; }
  local out failures total
  out="$("$script" "$BASE_PATH" "$WINDOW_HOURS" 2>/dev/null || true)"
  failures="$(printf '%s\n' "$out" | rg -o '([0-9]+) failures' -r '$1' | head -1)"
  total="$(printf '%s\n' "$out" \
    | rg -o '[0-9]+ calls' -r '' \
    | rg -o '[0-9]+' \
    | awk 'BEGIN{s=0}{s+=$1}END{print s}')"
  [[ -z "$failures" || -z "$total" || "$total" == "0" ]] && { echo "null"; return; }
  awk -v f="$failures" -v t="$total" 'BEGIN { printf "%.2f", ((t - f) * 100.0) / t }'
}

m_bash_failure_pct() {
  local script="$REPO_ROOT/scripts/analyze-keeper-bash-failures.sh"
  [[ -x "$script" ]] || { echo "null"; return; }
  "$script" "$BASE_PATH" "$WINDOW_HOURS" 2>/dev/null \
    | rg -o '[Ff]ailure[^0-9]*([0-9]+\.[0-9]+)' -r '$1' | head -1 || echo "null"
}

m_cascade_audit_failure_pct() {
  # Approximation: cascade_exhausted / cascade_attempt over window log.
  [[ -f "$LOG_TODAY" ]] || { echo "null"; return; }
  local exh att
  exh=$(rg --count 'cascade_exhausted' "$LOG_TODAY" 2>/dev/null || echo 0)
  att=$(rg --count 'cascade_attempt' "$LOG_TODAY" 2>/dev/null || echo 0)
  if [[ "$att" -eq 0 ]]; then echo "null"; return; fi
  awk -v e="$exh" -v a="$att" 'BEGIN { printf "%.2f", (e * 100.0) / a }'
}

m_docker_false_positive_24h() {
  [[ -f "$LOG_TODAY" ]] || { echo "0"; return; }
  # sandbox_image_missing count from today's log.
  rg --count 'sandbox_image_missing' "$LOG_TODAY" 2>/dev/null || echo 0
}

epoch_ms() {
  python3 -c 'import time; print(int(time.time()*1000))'
}

m_dashboard_proof_endpoints() {
  local endpoints=(/health /health?full=1 /api/v1/dashboard/goals /api/v1/verification/summary)
  local out="{"
  local first=1
  for ep in "${endpoints[@]}"; do
    local code start end ms
    start=$(epoch_ms)
    code=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "$DASHBOARD_HOST$ep" 2>/dev/null || echo "000")
    end=$(epoch_ms)
    ms=$(( end - start ))
    [[ $first -eq 1 ]] && first=0 || out+=","
    out+="\"$ep\":{\"code\":\"$code\",\"ms\":$ms}"
  done
  out+="}"
  printf '%s' "$out"
}

m_live_defect_issues() {
  command -v gh >/dev/null || { echo "null"; return; }
  gh issue list --repo jeong-sik/masc-mcp --label live-defect --state open --json number 2>/dev/null \
    | jq 'length' || echo "null"
}

# --- aggregation --------------------------------------------------------------

emit_json() {
  jq -n \
    --arg basepath "$BASE_PATH" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg window_hours "$WINDOW_HOURS" \
    --argjson open_backlog "$(m_open_backlog)" \
    --argjson p1_open "$(m_p1_open)" \
    --argjson pending_verification_gt_48h "$(m_pending_verification_gt_48h)" \
    --argjson posts_window "$(m_posts_window)" \
    --argjson comments_window "$(m_comments_window)" \
    --argjson high_churn_threads_48h "$(m_high_churn_threads_48h)" \
    --argjson warn_error_window "$(m_warn_error_window)" \
    --arg tool_call_success_pct "$(m_tool_call_success_pct)" \
    --arg bash_failure_pct "$(m_bash_failure_pct)" \
    --arg cascade_audit_failure_pct "$(m_cascade_audit_failure_pct)" \
    --argjson docker_false_positive_24h "$(m_docker_false_positive_24h)" \
    --argjson dashboard_proof "$(m_dashboard_proof_endpoints)" \
    --arg live_defect_open "$(m_live_defect_issues)" \
    '{
       schema: "board-slo-v1",
       basepath: $basepath,
       generated_at: $generated_at,
       window_hours: ($window_hours | tonumber),
       metrics: {
         open_backlog: $open_backlog,
         p1_open: $p1_open,
         pending_verification_gt_48h: $pending_verification_gt_48h,
         posts_window: $posts_window,
         comments_window: $comments_window,
         high_churn_threads_48h: $high_churn_threads_48h,
         warn_error_window: $warn_error_window,
         tool_call_success_pct: ($tool_call_success_pct | tonumber? // null),
         bash_failure_pct: ($bash_failure_pct | tonumber? // null),
         cascade_audit_failure_pct: ($cascade_audit_failure_pct | tonumber? // null),
         docker_false_positive_24h: $docker_false_positive_24h,
         dashboard_proof: $dashboard_proof,
         live_defect_open: ($live_defect_open | tonumber? // null)
       }
     }'
}

emit_table() {
  emit_json | jq -r '
    .metrics as $m
    | [
        ["metric", "value", "target"],
        ["open_backlog", ($m.open_backlog|tostring), "<= 40"],
        ["p1_open", ($m.p1_open|tostring), "<= 10"],
        ["pending_verification_gt_48h", ($m.pending_verification_gt_48h|tostring), "0"],
        ["posts_window", ($m.posts_window|tostring), "<= 275"],
        ["comments_window", ($m.comments_window|tostring), "<= 800"],
        ["high_churn_threads_48h", ($m.high_churn_threads_48h|tostring), "<= 10"],
        ["warn_error_window", ($m.warn_error_window|tostring), "<= 6500"],
        ["tool_call_success_pct", ($m.tool_call_success_pct|tostring), ">= 90"],
        ["bash_failure_pct", ($m.bash_failure_pct|tostring), "<= 20"],
        ["cascade_audit_failure_pct", ($m.cascade_audit_failure_pct|tostring), "<= 10"],
        ["docker_false_positive_24h", ($m.docker_false_positive_24h|tostring), "0"],
        ["live_defect_open", ($m.live_defect_open|tostring), "each linked"]
      ]
    | .[] | @tsv'
}

case "$OUTPUT_MODE" in
  json) emit_json ;;
  table) emit_table ;;
esac
