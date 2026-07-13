#!/usr/bin/env bash
# board-slo-extractor.sh — Board convergence SLO snapshot (PR-1).
#
# Read-only. Runtime 무변경. basepath SSOT 준수:
#   MASC_BASE_PATH env 우선 → config_dir_resolver fallback → hard fail.
# 절대 $HOME 또는 ~/me 하드코딩 금지.
#
# Output: 13-row SLO table per Goal goal-board-live-issue-convergence-20260519.
# Modes: --json (default), --table (human render via jq), --offline (fixtures/CI).

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
readonly TOOL_CALLS_DIR="$MASC_DIR/tool_calls"
readonly DOCKER_PLAYGROUND_DIR="$MASC_DIR/playground/docker"
readonly TODAY="$(date -u +%Y-%m-%d)"
readonly LOG_TODAY="$LOGS_DIR/system_log_${TODAY}.jsonl"

WINDOW_HOURS=24
OUTPUT_MODE=json
DASHBOARD_HOST="http://127.0.0.1:8935"
OFFLINE_MODE=0
DASHBOARD_TIMEOUT_SEC="${MASC_BOARD_SLO_DASHBOARD_TIMEOUT_SEC:-5}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --window-hours) WINDOW_HOURS="$2"; shift 2 ;;
    --table) OUTPUT_MODE=table; shift ;;
    --json) OUTPUT_MODE=json; shift ;;
    --offline) OFFLINE_MODE=1; shift ;;
    --dashboard-host) DASHBOARD_HOST="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

readonly WINDOW_SEC=$(( WINDOW_HOURS * 3600 ))

# --- metric primitives --------------------------------------------------------

date_path_days_ago() {
  local days_ago="$1"
  date -u -v-"${days_ago}"d +%Y-%m/%d 2>/dev/null \
    || date -u -d "-${days_ago} days" +%Y-%m/%d 2>/dev/null
}

date_ymd_days_ago() {
  local days_ago="$1"
  date -u -v-"${days_ago}"d +%Y-%m-%d 2>/dev/null \
    || date -u -d "-${days_ago} days" +%Y-%m-%d 2>/dev/null
}

recent_dated_jsonl_files() {
  local dir="$1"
  local days=$(( (WINDOW_HOURS + 23) / 24 ))
  local i rel file
  for i in $(seq 0 "$days"); do
    rel="$(date_path_days_ago "$i" || true)"
    [[ -n "$rel" ]] || continue
    file="$dir/$rel.jsonl"
    [[ -f "$file" ]] && printf '%s\n' "$file"
  done
}

recent_system_log_files() {
  local days=$(( (WINDOW_HOURS + 23) / 24 ))
  local i ymd file
  for i in $(seq 0 "$days"); do
    ymd="$(date_ymd_days_ago "$i" || true)"
    [[ -n "$ymd" ]] || continue
    file="$LOGS_DIR/system_log_${ymd}.jsonl"
    [[ -f "$file" ]] && printf '%s\n' "$file"
  done
}

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
  jq -s '[.[] | select((.level // "") | test("^(WARN|ERROR|WARNING)$"))] | length' "$LOG_TODAY"
}

m_tool_call_success_pct() {
  [[ -d "$TOOL_CALLS_DIR" ]] || { echo "null"; return; }
  local files=()
  local file
  while IFS= read -r file; do
    files+=("$file")
  done < <(recent_dated_jsonl_files "$TOOL_CALLS_DIR")
  [[ "${#files[@]}" -gt 0 ]] || { echo "null"; return; }
  jq -s --argjson cutoff "$(( $(date +%s) - WINDOW_SEC ))" '
    def ts_epoch:
      if (.ts | type) == "number" then .ts
      elif (.ts | type) == "string" then (.ts | fromdateiso8601? // 0)
      else 0 end;
    [ .[] | select(ts_epoch >= $cutoff) ] as $rows
    | ($rows | length) as $total
    | if $total == 0 then empty
      else
        ([ $rows[] | select(.success == true) ] | length) as $ok
        | (($ok * 10000 / $total | floor) / 100)
      end
  ' "${files[@]}" 2>/dev/null || echo "null"
}

m_execute_failure_pct() {
  [[ -d "$TOOL_CALLS_DIR" ]] || { echo "null"; return; }
  local files=()
  local file
  while IFS= read -r file; do
    files+=("$file")
  done < <(recent_dated_jsonl_files "$TOOL_CALLS_DIR")
  [[ "${#files[@]}" -gt 0 ]] || { echo "null"; return; }
  jq -s --argjson cutoff "$(( $(date +%s) - WINDOW_SEC ))" '
    def ts_epoch:
      if (.ts | type) == "number" then .ts
      elif (.ts | type) == "string" then (.ts | fromdateiso8601? // 0)
      else 0 end;
    [ .[]
      | select(ts_epoch >= $cutoff)
      | select(.tool == "Execute" or .tool == "tool_execute")
    ] as $rows
    | ($rows | length) as $total
    | if $total == 0 then empty
      else
        ([ $rows[] | select(.success == false) ] | length) as $fail
        | (($fail * 10000 / $total | floor) / 100)
      end
  ' "${files[@]}" 2>/dev/null || echo "null"
}

m_runtime_audit_failure_pct() {
  [[ -d "$LOGS_DIR" ]] || { echo "null"; return; }
  local files=()
  local file
  while IFS= read -r file; do
    files+=("$file")
  done < <(recent_system_log_files)
  if [[ "${#files[@]}" -eq 0 && -f "$LOG_TODAY" ]]; then
    files=("$LOG_TODAY")
  fi
  [[ "${#files[@]}" -gt 0 ]] || { echo "null"; return; }
  jq -s --argjson cutoff "$(( $(date +%s) - WINDOW_SEC ))" '
    def ts_epoch:
      if (.ts | type) == "number" then .ts
      elif (.ts | type) == "string" then (.ts | fromdateiso8601? // 0)
      else 0 end;
    [ .[]
      | select(ts_epoch >= $cutoff)
      | select((.details.event // .event // "") == "runtime_attempt_terminal")
    ] as $rows
    | ($rows | length) as $total
    | if $total == 0 then empty
      else
        ([ $rows[] | select((.details.outcome // .outcome // "") == "failure") ] | length) as $fail
        | (($fail * 10000 / $total | floor) / 100)
      end
  ' "${files[@]}" 2>/dev/null || echo "null"
}

m_docker_false_positive_24h() {
  [[ -f "$LOG_TODAY" ]] || { echo "0"; return; }
  jq -s '[.[] | select(((.event // "") + " " + (.message // "")) | contains("image_not_found"))] | length' "$LOG_TODAY"
}

m_live_defect_signatures() {
  [[ -f "$LOG_TODAY" ]] || {
    jq -n '{
      project_snapshot_timeout: 0,
      process_eio_1s_timeout: 0,
      process_eio_5s_timeout: 0,
      sandbox_image_not_found: 0,
      host_fd_hotspot_budget_exhausted: 0,
      docker_worktree_gitdir_prepared: 0,
      docker_worktree_gitdir_restored: 0
    }'
    return
  }
  jq -s '
    def msg: (.message // "");
    {
      project_snapshot_timeout:
        ([.[] | select(msg | contains("project-snapshot async shell refresh timed out"))] | length),
      process_eio_1s_timeout:
        ([.[] | select(msg | test("\\[Process_eio\\] Timeout after 1s"))] | length),
      process_eio_5s_timeout:
        ([.[] | select(msg | test("\\[Process_eio\\] Timeout after 5s"))] | length),
      sandbox_image_not_found:
        ([.[] | select(((.event // "") + " " + msg) | contains("image_not_found"))] | length),
      host_fd_hotspot_budget_exhausted:
        ([.[] | select(msg | contains("host_fd_hotspot_budget_exhausted"))] | length),
      docker_worktree_gitdir_prepared:
        ([.[] | select(msg | contains("docker worktree gitdir path") and contains("prepared"))] | length),
      docker_worktree_gitdir_restored:
        ([.[] | select(msg | contains("docker worktree gitdir path") and contains("restored"))] | length)
    }' "$LOG_TODAY"
}

m_docker_playground_worktrees() {
  local worktrees_dirs=0
  local worktree_entries=0
  if [[ -d "$DOCKER_PLAYGROUND_DIR" ]]; then
    local keeper_dir repos_dir repo_dir worktrees_dir wt_path
    for keeper_dir in "$DOCKER_PLAYGROUND_DIR"/*; do
      [[ -d "$keeper_dir" ]] || continue
      repos_dir="$keeper_dir/repos"
      [[ -d "$repos_dir" ]] || continue
      for repo_dir in "$repos_dir"/*; do
        [[ -d "$repo_dir" ]] || continue
        worktrees_dir="$repo_dir/.worktrees"
        [[ -d "$worktrees_dir" ]] || continue
        worktrees_dirs=$((worktrees_dirs + 1))
        for wt_path in "$worktrees_dir"/*; do
          [[ -d "$wt_path" ]] || continue
          worktree_entries=$((worktree_entries + 1))
        done
      done
    done
  fi
  jq -n \
    --argjson worktrees_dirs "$worktrees_dirs" \
    --argjson worktree_entries "$worktree_entries" \
    '{worktrees_dirs: $worktrees_dirs, worktree_entries: $worktree_entries}'
}

epoch_ms() {
  python3 -c 'import time; print(int(time.time()*1000))'
}

m_dashboard_proof_endpoints() {
  [[ "$OFFLINE_MODE" -eq 0 ]] || { echo "{}"; return; }
  local endpoints=(/health /health?full=1 /api/v1/dashboard/goals /api/v1/verification/summary)
  local out="{"
  local first=1
  for ep in "${endpoints[@]}"; do
    local code start end ms
    start=$(epoch_ms)
    code="$(curl -sS --max-time "$DASHBOARD_TIMEOUT_SEC" -o /dev/null -w '%{http_code}' "$DASHBOARD_HOST$ep" 2>/dev/null || true)"
    [[ -n "$code" ]] || code="000"
    end=$(epoch_ms)
    ms=$(( end - start ))
    [[ $first -eq 1 ]] && first=0 || out+=","
    out+="\"$ep\":{\"code\":\"$code\",\"ms\":$ms}"
  done
  out+="}"
  printf '%s' "$out"
}

m_live_defect_issues() {
  [[ "$OFFLINE_MODE" -eq 0 ]] || { echo "null"; return; }
  command -v gh >/dev/null || { echo "null"; return; }
  gh issue list --repo jeong-sik/masc --label live-defect --state open --json number 2>/dev/null \
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
    --arg execute_failure_pct "$(m_execute_failure_pct)" \
    --arg runtime_audit_failure_pct "$(m_runtime_audit_failure_pct)" \
    --argjson docker_false_positive_24h "$(m_docker_false_positive_24h)" \
    --argjson live_defect_signatures "$(m_live_defect_signatures)" \
    --argjson docker_playground_worktrees "$(m_docker_playground_worktrees)" \
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
         execute_failure_pct: ($execute_failure_pct | tonumber? // null),
         runtime_audit_failure_pct: ($runtime_audit_failure_pct | tonumber? // null),
         docker_false_positive_24h: $docker_false_positive_24h,
         live_defect_signatures: $live_defect_signatures,
         docker_playground_worktrees: $docker_playground_worktrees,
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
        ["execute_failure_pct", ($m.execute_failure_pct|tostring), "<= 20"],
        ["runtime_audit_failure_pct", ($m.runtime_audit_failure_pct|tostring), "<= 10"],
        ["docker_false_positive_24h", ($m.docker_false_positive_24h|tostring), "0"],
        ["live_defect_open", ($m.live_defect_open|tostring), "each linked"]
      ]
    | .[] | @tsv'
}

case "$OUTPUT_MODE" in
  json) emit_json ;;
  table) emit_table ;;
esac
