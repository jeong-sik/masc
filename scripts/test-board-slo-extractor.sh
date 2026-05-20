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
{"level":"WARN","event":"cascade_attempt"}
{"level":"ERROR","event":"cascade_attempt sandbox_image_missing"}
{"level":"WARNING","event":"cascade_exhausted"}
{"level":"INFO","event":"cascade_attempt"}
{"level":"INFO","event":"cascade_attempt"}
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
check '.metrics.warn_error_window == 3'
check '.metrics.cascade_audit_failure_pct == 25'
check '.metrics.docker_false_positive_24h == 1'
check '.metrics.dashboard_proof == {}'
check '.metrics.live_defect_open == null'

printf 'board-slo-extractor fixture test passed\n'
