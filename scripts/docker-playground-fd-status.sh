#!/usr/bin/env bash
# Report Docker playground worktree fanout and FD holders referencing it.

set -euo pipefail

ROOT=""
LIMIT=20
FD_WARN="${MASC_DOCKER_PLAYGROUND_FD_WARN:-10000}"
WORKTREE_WARN="${MASC_DOCKER_PLAYGROUND_WORKTREE_WARN:-100}"
CLEANUP_SUMMARY=0
CLEANUP_DAYS=7
AGGRESSIVE_CLEANUP_DAYS=""

usage() {
  cat <<'EOF'
docker-playground-fd-status.sh - Docker playground FD hotspot visibility

Usage:
  scripts/docker-playground-fd-status.sh [--root PATH] [--limit N]

Options:
  --root PATH   Docker playground root. Defaults to
                $MASC_BASE_PATH/.masc/playground/docker, then
                $PWD/.masc/playground/docker.
  --limit N     Number of FD holder rows to print. Default: 20.
  --fd-warn N   Warn when a single process holds at least N FDs under root.
                Default: $MASC_DOCKER_PLAYGROUND_FD_WARN, then 10000.
  --worktree-warn N
                Warn when root contains at least N worktree entries.
                Default: $MASC_DOCKER_PLAYGROUND_WORKTREE_WARN, then 100.
  --cleanup-summary
                Run cleanup dry-runs and print summary counters for root and
                the largest keeper/repo bucket. No files are removed.
  --cleanup-days N
                Days threshold for cleanup dry-run commands and summaries.
                Default: 7.
  --aggressive-cleanup-days N
                Also print a second, more aggressive dry-run summary. This is
                diagnostic only; use --apply manually after review.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --limit) LIMIT="${2:-}"; shift 2 ;;
    --fd-warn) FD_WARN="${2:-}"; shift 2 ;;
    --worktree-warn) WORKTREE_WARN="${2:-}"; shift 2 ;;
    --cleanup-summary) CLEANUP_SUMMARY=1; shift ;;
    --cleanup-days)
      CLEANUP_SUMMARY=1
      CLEANUP_DAYS="${2:-}"
      if [ -z "$CLEANUP_DAYS" ]; then
        echo "--cleanup-days requires a value" >&2
        exit 2
      fi
      shift 2
      ;;
    --aggressive-cleanup-days)
      CLEANUP_SUMMARY=1
      AGGRESSIVE_CLEANUP_DAYS="${2:-}"
      if [ -z "$AGGRESSIVE_CLEANUP_DAYS" ]; then
        echo "--aggressive-cleanup-days requires a value" >&2
        exit 2
      fi
      shift 2
      ;;
    -h|--help|help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

for numeric_arg in LIMIT FD_WARN WORKTREE_WARN CLEANUP_DAYS; do
  numeric_value="${!numeric_arg}"
  if ! [[ "$numeric_value" =~ ^[0-9]+$ ]]; then
    case "$numeric_arg" in
      LIMIT) numeric_flag="limit" ;;
      FD_WARN) numeric_flag="fd-warn" ;;
      WORKTREE_WARN) numeric_flag="worktree-warn" ;;
      CLEANUP_DAYS) numeric_flag="cleanup-days" ;;
      *) numeric_flag="$numeric_arg" ;;
    esac
    echo "--$numeric_flag must be a non-negative integer (got: $numeric_value)" >&2
    exit 2
  fi
done

if [ -n "$AGGRESSIVE_CLEANUP_DAYS" ] && ! [[ "$AGGRESSIVE_CLEANUP_DAYS" =~ ^[0-9]+$ ]]; then
  echo "--aggressive-cleanup-days must be a non-negative integer (got: $AGGRESSIVE_CLEANUP_DAYS)" >&2
  exit 2
fi

if [ -z "$ROOT" ]; then
  BASE="${MASC_BASE_PATH:-$(pwd)}"
  ROOT="$BASE/.masc/playground/docker"
fi

ROOT="${ROOT%/}"

worktrees_dirs=0
worktree_entries=0
top_holder_fd_count=0
fanout_tmp="$(mktemp "${TMPDIR:-/tmp}/masc-docker-playground-fanout.XXXXXX")"
holders_tmp=""

cleanup_tmp() {
  rm -f "$fanout_tmp"
  if [ -n "$holders_tmp" ]; then
    rm -f "$holders_tmp"
  fi
}
trap cleanup_tmp EXIT

if [ -d "$ROOT" ]; then
  for keeper_dir in "$ROOT"/*; do
    [ -d "$keeper_dir" ] || continue
    repos_dir="$keeper_dir/repos"
    [ -d "$repos_dir" ] || continue
    for repo_dir in "$repos_dir"/*; do
      [ -d "$repo_dir" ] || continue
      worktrees_dir="$repo_dir/.worktrees"
      [ -d "$worktrees_dir" ] || continue
      repo_entries=0
      worktrees_dirs=$((worktrees_dirs + 1))
      for wt_path in "$worktrees_dir"/*; do
        [ -d "$wt_path" ] || continue
        worktree_entries=$((worktree_entries + 1))
        repo_entries=$((repo_entries + 1))
      done
      if [ "$repo_entries" -gt 0 ]; then
        printf '%s %s %s %s\n' "$repo_entries" \
          "$(basename "$keeper_dir")" "$(basename "$repo_dir")" "$worktrees_dir" \
          >>"$fanout_tmp"
      fi
    done
  done
fi

echo "root=$ROOT"
echo "worktrees_dirs=$worktrees_dirs"
echo "worktree_entries=$worktree_entries"
echo "worktree_warn_threshold=$WORKTREE_WARN"
echo "fd_warn_threshold=$FD_WARN"

echo ""
echo "Top worktree fanout by keeper/repo:"
echo "worktree_fanout_columns=count keeper repo worktrees_dir"
if [ -s "$fanout_tmp" ]; then
  sort -rn "$fanout_tmp" | head -n "$LIMIT"
else
  echo "0 none none none"
fi

emit_top_fanout_action() {
  [ -s "$fanout_tmp" ] || return 0
  local top_fanout_line top_fanout_count top_fanout_keeper top_fanout_repo
  local quoted_root quoted_keeper quoted_repo
  top_fanout_line="$(sort -rn "$fanout_tmp" | head -n 1)"
  set -- $top_fanout_line
  top_fanout_count="${1:-0}"
  top_fanout_keeper="${2:-}"
  top_fanout_repo="${3:-}"
  [ "$top_fanout_count" -gt 0 ] || return 0
  [ -n "$top_fanout_keeper" ] || return 0
  [ -n "$top_fanout_repo" ] || return 0
  quoted_root="$(printf '%q' "$ROOT")"
  quoted_keeper="$(printf '%q' "$top_fanout_keeper")"
  quoted_repo="$(printf '%q' "$top_fanout_repo")"
  echo "top_fanout_count=$top_fanout_count"
  echo "top_fanout_keeper=$top_fanout_keeper"
  echo "top_fanout_repo=$top_fanout_repo"
  echo "top_fanout_cleanup_dry_run_command=scripts/cleanup-docker-playground-worktrees.sh --root $quoted_root --keeper $quoted_keeper --repo $quoted_repo --days $CLEANUP_DAYS"
  echo "top_fanout_broken_dry_run_command=scripts/cleanup-docker-playground-worktrees.sh --root $quoted_root --keeper $quoted_keeper --repo $quoted_repo --days $CLEANUP_DAYS --include-broken"
}

emit_top_fanout_action

cleanup_script_path() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s\n' "$script_dir/cleanup-docker-playground-worktrees.sh"
}

summary_field() {
  local summary="$1"
  local key="$2"
  printf '%s\n' "$summary" | sed -n "s/.* ${key}=\([0-9][0-9]*\).*/\1/p"
}

emit_cleanup_summary_fields() {
  local prefix="$1"
  local days="$2"
  local summary="$3"
  local key value
  echo "${prefix}_days=$days"
  for key in scanned candidates removed recent dirty active broken broken_candidates broken_removed failed; do
    value="$(summary_field "$summary" "$key")"
    if [ -z "$value" ]; then
      value="0"
    fi
    echo "${prefix}_${key}=$value"
  done
}

emit_cleanup_projection() {
  local prefix="$1"
  local key="$2"
  local total="$3"
  local summary="$4"
  local candidates projected
  candidates="$(summary_field "$summary" candidates)"
  if [ -z "$candidates" ]; then
    candidates="0"
  fi
  if [ "$candidates" -ge "$total" ]; then
    projected=0
  else
    projected=$((total - candidates))
  fi
  echo "${prefix}_${key}=$projected"
}

run_cleanup_summary() {
  local prefix="$1"
  local days="$2"
  local keeper="${3:-}"
  local repo="${4:-}"
  local projection_key="${5:-}"
  local projection_total="${6:-}"
  local cleanup_script
  local summary
  cleanup_script="$(cleanup_script_path)"
  if [ ! -x "$cleanup_script" ]; then
    echo "${prefix}_unavailable=cleanup_script_missing"
    return 0
  fi
  if [ -n "$keeper" ] && [ -n "$repo" ]; then
    summary="$("$cleanup_script" --root "$ROOT" --keeper "$keeper" --repo "$repo" --days "$days" \
      | awk '/^Summary / { line=$0 } END { print line }')"
  else
    summary="$("$cleanup_script" --root "$ROOT" --days "$days" \
      | awk '/^Summary / { line=$0 } END { print line }')"
  fi
  if [ -z "$summary" ]; then
    echo "${prefix}_unavailable=cleanup_summary_missing"
    return 0
  fi
  emit_cleanup_summary_fields "$prefix" "$days" "$summary"
  if [ -n "$projection_key" ] && [ -n "$projection_total" ]; then
    emit_cleanup_projection "$prefix" "$projection_key" "$projection_total" "$summary"
  fi
}

emit_cleanup_summaries() {
  [ "$CLEANUP_SUMMARY" -eq 1 ] || return 0
  echo ""
  echo "Cleanup dry-run summary:"
  run_cleanup_summary "cleanup_summary" "$CLEANUP_DAYS" "" "" \
    "projected_worktree_entries" "$worktree_entries"
  if [ -s "$fanout_tmp" ]; then
    local top_fanout_line top_fanout_count top_fanout_keeper top_fanout_repo
    top_fanout_line="$(sort -rn "$fanout_tmp" | head -n 1)"
    set -- $top_fanout_line
    top_fanout_count="${1:-0}"
    top_fanout_keeper="${2:-}"
    top_fanout_repo="${3:-}"
    if [ "$top_fanout_count" -gt 0 ] && [ -n "$top_fanout_keeper" ] && [ -n "$top_fanout_repo" ]; then
      run_cleanup_summary "top_fanout_cleanup_summary" "$CLEANUP_DAYS" \
        "$top_fanout_keeper" "$top_fanout_repo" "projected_count" "$top_fanout_count"
    fi
  fi
  if [ -n "$AGGRESSIVE_CLEANUP_DAYS" ]; then
    run_cleanup_summary "aggressive_cleanup_summary" "$AGGRESSIVE_CLEANUP_DAYS" "" "" \
      "projected_worktree_entries" "$worktree_entries"
    if [ -s "$fanout_tmp" ]; then
      local top_fanout_line top_fanout_count top_fanout_keeper top_fanout_repo
      top_fanout_line="$(sort -rn "$fanout_tmp" | head -n 1)"
      set -- $top_fanout_line
      top_fanout_count="${1:-0}"
      top_fanout_keeper="${2:-}"
      top_fanout_repo="${3:-}"
      if [ "$top_fanout_count" -gt 0 ] && [ -n "$top_fanout_keeper" ] && [ -n "$top_fanout_repo" ]; then
        run_cleanup_summary "top_fanout_aggressive_cleanup_summary" \
          "$AGGRESSIVE_CLEANUP_DAYS" "$top_fanout_keeper" "$top_fanout_repo" \
          "projected_count" "$top_fanout_count"
      fi
    fi
  fi
}

emit_hotspot_status() {
  local hotspot_status="ok"
  local hotspot_reasons=""
  if [ "$WORKTREE_WARN" -gt 0 ] && [ "$worktree_entries" -ge "$WORKTREE_WARN" ]; then
    hotspot_status="warning"
    hotspot_reasons="${hotspot_reasons}worktree_entries,"
  fi
  if [ "$FD_WARN" -gt 0 ] && [ "$top_holder_fd_count" -ge "$FD_WARN" ]; then
    hotspot_status="warning"
    hotspot_reasons="${hotspot_reasons}top_holder_fd_count,"
  fi
  hotspot_reasons="${hotspot_reasons%,}"
  if [ -z "$hotspot_reasons" ]; then
    hotspot_reasons="none"
  fi
  echo "hotspot_status=$hotspot_status"
  echo "hotspot_reasons=$hotspot_reasons"
  if [ "$hotspot_status" = "warning" ]; then
    quoted_root="$(printf '%q' "$ROOT")"
    echo "cleanup_dry_run_command=scripts/cleanup-docker-playground-worktrees.sh --root $quoted_root --days 7"
    echo "cleanup_broken_dry_run_command=scripts/cleanup-docker-playground-worktrees.sh --root $quoted_root --days 7 --include-broken"
    if [ "$FD_WARN" -gt 0 ] && [ "$top_holder_fd_count" -ge "$FD_WARN" ]; then
      echo "docker_desktop_restart_recommended=true"
      echo "docker_desktop_restart_reason=macOS Docker Desktop may retain shared-file FDs until the VM restarts"
    fi
  fi
}

if ! command -v lsof >/dev/null 2>&1; then
  echo "fd_holders=unavailable (lsof not found)"
  emit_hotspot_status
  emit_cleanup_summaries
  exit 0
fi

echo ""
echo "Top FD holders referencing root:"
holders_tmp="$(mktemp "${TMPDIR:-/tmp}/masc-docker-playground-fd.XXXXXX")"
if lsof -n -P +c 64 2>/dev/null \
  | awk -v root="$ROOT/" '
      NR > 1 {
        name = $9
        for (i = 10; i <= NF; i++) {
          name = name " " $i
        }
        if (index(name, root) == 1) {
          count[$2]++
          cmd[$2] = $1
          type_count[$2, $5]++
        }
      }
      END {
        for (pid in count) {
          types = ""
          for (key in type_count) {
            split(key, parts, SUBSEP)
            if (parts[1] == pid) {
              types = types parts[2] "=" type_count[key] ","
            }
          }
          sub(/,$/, "", types)
          print count[pid], pid, cmd[pid], types
        }
      }' | sort -rn >"$holders_tmp"; then
  top_holder_fd_count="$(awk 'NR == 1 {print $1 + 0; found = 1} END {if (!found) print 0}' "$holders_tmp")"
  head -n "$LIMIT" "$holders_tmp"
  echo "top_holder_fd_count=$top_holder_fd_count"
  emit_hotspot_status
  emit_cleanup_summaries
else
  echo "fd_holders=unavailable (lsof failed)"
  emit_hotspot_status
  emit_cleanup_summaries
fi
