#!/usr/bin/env bash
# Report Docker playground worktree fanout and FD holders referencing it.

set -euo pipefail

ROOT=""
LIMIT=20
FD_WARN="${MASC_DOCKER_PLAYGROUND_FD_WARN:-10000}"
WORKTREE_WARN="${MASC_DOCKER_PLAYGROUND_WORKTREE_WARN:-100}"

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
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --limit) LIMIT="${2:-}"; shift 2 ;;
    --fd-warn) FD_WARN="${2:-}"; shift 2 ;;
    --worktree-warn) WORKTREE_WARN="${2:-}"; shift 2 ;;
    -h|--help|help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

for numeric_arg in LIMIT FD_WARN WORKTREE_WARN; do
  numeric_value="${!numeric_arg}"
  if ! [[ "$numeric_value" =~ ^[0-9]+$ ]]; then
    case "$numeric_arg" in
      LIMIT) numeric_flag="limit" ;;
      FD_WARN) numeric_flag="fd-warn" ;;
      WORKTREE_WARN) numeric_flag="worktree-warn" ;;
      *) numeric_flag="$numeric_arg" ;;
    esac
    echo "--$numeric_flag must be a non-negative integer (got: $numeric_value)" >&2
    exit 2
  fi
done

if [ -z "$ROOT" ]; then
  BASE="${MASC_BASE_PATH:-$(pwd)}"
  ROOT="$BASE/.masc/playground/docker"
fi

ROOT="${ROOT%/}"

worktrees_dirs=0
worktree_entries=0
top_holder_fd_count=0

if [ -d "$ROOT" ]; then
  for keeper_dir in "$ROOT"/*; do
    [ -d "$keeper_dir" ] || continue
    repos_dir="$keeper_dir/repos"
    [ -d "$repos_dir" ] || continue
    for repo_dir in "$repos_dir"/*; do
      [ -d "$repo_dir" ] || continue
      worktrees_dir="$repo_dir/.worktrees"
      [ -d "$worktrees_dir" ] || continue
      worktrees_dirs=$((worktrees_dirs + 1))
      for wt_path in "$worktrees_dir"/*; do
        [ -d "$wt_path" ] || continue
        worktree_entries=$((worktree_entries + 1))
      done
    done
  done
fi

echo "root=$ROOT"
echo "worktrees_dirs=$worktrees_dirs"
echo "worktree_entries=$worktree_entries"
echo "worktree_warn_threshold=$WORKTREE_WARN"
echo "fd_warn_threshold=$FD_WARN"

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
  exit 0
fi

echo ""
echo "Top FD holders referencing root:"
holders_tmp="$(mktemp "${TMPDIR:-/tmp}/masc-docker-playground-fd.XXXXXX")"
trap 'rm -f "$holders_tmp"' EXIT
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
else
  echo "fd_holders=unavailable (lsof failed)"
  emit_hotspot_status
fi
