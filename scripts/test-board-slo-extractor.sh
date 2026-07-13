#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/board-slo-fixture.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

masc_dir="$fixture/.masc"
mkdir -p "$masc_dir/tasks" "$masc_dir/logs"

now="$(date +%s)"
old=$((now - 200000))
today="$(date -u +%Y-%m-%d)"
tool_month="$(date -u +%Y-%m)"
tool_day="$(date -u +%d)"
mkdir -p "$masc_dir/tool_calls/$tool_month"

cat >"$masc_dir/tasks/backlog.json" <<JSON
{
  "version": 1,
  "last_updated": $now,
  "tasks": [
    {"id": "task-1", "title": "p1 todo", "status": "todo", "priority": 1},
    {"id": "task-2", "title": "p1 awaiting", "status": "awaiting_verification", "priority": 1, "verification_submitted_at": $old},
    {"id": "task-3", "title": "p2 in progress", "status": "in_progress", "priority": 2},
    {"id": "task-4", "title": "p2 todo", "status": "todo", "priority": 2},
    {"id": "task-5", "title": "done", "status": "done", "priority": 1},
    {"id": "task-6", "title": "cancelled", "status": "cancelled", "priority": 1}
  ]
}
JSON

cat >"$masc_dir/board_posts.jsonl" <<JSONL
{"id":"post-1","created_at":$now}
{"id":"post-2","created_at":$((now - 60))}
{"id":"post-old","created_at":$old}
JSONL

for i in $(seq 1 20); do
  printf '{"id":"comment-%s","post_id":"hot","created_at":%s}\n' "$i" "$now" >>"$masc_dir/board_comments.jsonl"
done
printf '{"id":"comment-old","post_id":"old","created_at":%s}\n' "$old" >>"$masc_dir/board_comments.jsonl"

cat >"$masc_dir/logs/system_log_${today}.jsonl" <<JSONL
{"ts":$now,"level":"WARN","details":{"event":"runtime_attempt_terminal","outcome":"success"}}
{"ts":$now,"level":"ERROR","event":"image_not_found","details":{"event":"runtime_attempt_terminal","outcome":"failure"}}
{"ts":$now,"level":"WARNING","details":{"event":"runtime_attempt_terminal","outcome":"success"}}
{"ts":$now,"level":"INFO","details":{"event":"runtime_attempt_terminal","outcome":"success"}}
{"ts":$now,"level":"WARN","message":"project-snapshot async shell refresh timed out (5.0s)"}
{"ts":$now,"level":"WARN","message":"[Process_eio] Timeout after 1s: '/bin/bash' '-lc' 'git status -sb 2>&1'"}
{"ts":$now,"level":"WARN","message":"[Process_eio] Timeout after 5s (command): '/bin/bash' '-lc' 'scripts/dune-local.sh build test/test_operator_control.exe 2>&1'"}
{"ts":$now,"level":"INFO","message":"verifier: prepared 60 docker worktree gitdir path(s) under /fixture/.masc/playground/docker/verifier"}
{"ts":$now,"level":"INFO","message":"verifier: restored 60 docker worktree gitdir path(s) under /fixture/.masc/playground/docker/verifier"}
{"ts":$now,"level":"ERROR","message":"host_fd_hotspot_budget_exhausted"}
{"ts":$old,"level":"INFO","details":{"event":"runtime_attempt_terminal","outcome":"failure"}}
JSONL

mkdir -p \
  "$masc_dir/playground/docker/verifier/repos/masc/.worktrees/task-a" \
  "$masc_dir/playground/docker/verifier/repos/masc/.worktrees/task-b"

cat >"$masc_dir/tool_calls/$tool_month/$tool_day.jsonl" <<JSONL
{"ts":$now,"tool":"keeper_board_post","success":true,"duration_ms":10}
{"ts":$now,"tool":"keeper_board_comment","success":true,"duration_ms":20}
{"ts":$now,"tool":"Execute","success":true,"duration_ms":30}
{"ts":$now,"tool":"Execute","success":false,"duration_ms":40}
{"ts":$old,"tool":"Execute","success":true,"duration_ms":50}
JSONL

json="$(MASC_BASE_PATH="$fixture" "$REPO_ROOT/scripts/board-slo-extractor.sh" --json --offline)"

check() {
  local expr="$1"
  printf '%s\n' "$json" | jq -e "$expr" >/dev/null
}

check '.schema == "board-slo-v1"'
check '.metrics.open_backlog == 4'
check '.metrics.p1_open == 2'
check '.metrics.pending_verification_gt_48h == 1'
check '.metrics.posts_window == 2'
check '.metrics.comments_window == 20'
check '.metrics.high_churn_threads_48h == 1'
check '.metrics.warn_error_window == 7'
check '.metrics.tool_call_success_pct == 75'
check '.metrics.execute_failure_pct == 50'
check '.metrics.runtime_audit_failure_pct == 25'
check '.metrics.docker_false_positive_24h == 1'
check '.metrics.live_defect_signatures.project_snapshot_timeout == 1'
check '.metrics.live_defect_signatures.process_eio_1s_timeout == 1'
check '.metrics.live_defect_signatures.process_eio_5s_timeout == 1'
check '.metrics.live_defect_signatures.sandbox_image_not_found == 1'
check '.metrics.live_defect_signatures.host_fd_hotspot_budget_exhausted == 1'
check '.metrics.live_defect_signatures.docker_worktree_gitdir_prepared == 1'
check '.metrics.live_defect_signatures.docker_worktree_gitdir_restored == 1'
check '.metrics.docker_playground_worktrees.worktrees_dirs == 1'
check '.metrics.docker_playground_worktrees.worktree_entries == 2'
check '.metrics.dashboard_proof == {}'
check '.metrics.live_defect_open == null'

printf 'board-slo-extractor fixture test passed\n'
