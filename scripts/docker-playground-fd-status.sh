#!/usr/bin/env bash
# Report Docker playground worktree fanout and FD holders referencing it.

set -euo pipefail

ROOT=""
LIMIT=20

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
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --limit) LIMIT="${2:-}"; shift 2 ;;
    -h|--help|help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if ! [[ "$LIMIT" =~ ^[0-9]+$ ]]; then
  echo "--limit must be a non-negative integer (got: $LIMIT)" >&2
  exit 2
fi

if [ -z "$ROOT" ]; then
  BASE="${MASC_BASE_PATH:-$(pwd)}"
  ROOT="$BASE/.masc/playground/docker"
fi

ROOT="${ROOT%/}"

worktrees_dirs=0
worktree_entries=0

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

if ! command -v lsof >/dev/null 2>&1; then
  echo "fd_holders=unavailable (lsof not found)"
  exit 0
fi

echo ""
echo "Top FD holders referencing root:"
if ! lsof -n -P +c 64 2>/dev/null \
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
      }' \
  | sort -rn \
  | head -n "$LIMIT"; then
  echo "fd_holders=unavailable (lsof failed)"
fi
