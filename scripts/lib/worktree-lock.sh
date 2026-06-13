# Worktree concurrency lock primitives.
#
# Usage:
#   source scripts/lib/worktree-lock.sh
#   worktree_lock_acquire "/path/to/.worktrees/feature-x" "agent-name" || exit 1
#   ... do work ...
#   worktree_lock_release "/path/to/.worktrees/feature-x"
#
# A lock is a file at <worktree>/.masc-lock containing the agent name and PID.
# Stale locks (PID no longer alive) are automatically reclaimed.

worktree_lock_path() {
  local wt_path="$1"
  printf '%s/.masc-lock' "$wt_path"
}

worktree_lock_is_stale() {
  local lock_file="$1"
  local pid
  pid="$(awk '{print $NF}' "$lock_file" 2>/dev/null || true)"
  [[ -z "$pid" ]] && return 0
  ! kill -0 "$pid" 2>/dev/null
}

worktree_lock_check() {
  local wt_path="$1"
  local lock_file
  lock_file="$(worktree_lock_path "$wt_path")"
  if [[ -f "$lock_file" ]]; then
    if worktree_lock_is_stale "$lock_file"; then
      return 0
    fi
    return 1
  fi
  return 0
}

worktree_lock_owner() {
  local wt_path="$1"
  local lock_file
  lock_file="$(worktree_lock_path "$wt_path")"
  if [[ -f "$lock_file" ]]; then
    cat "$lock_file" 2>/dev/null || true
  fi
}

worktree_lock_acquire() {
  local wt_path="$1"
  local agent_name="${2:-unknown}"
  local lock_file
  lock_file="$(worktree_lock_path "$wt_path")"

  if [[ -f "$lock_file" ]]; then
    if ! worktree_lock_is_stale "$lock_file"; then
      return 1
    fi
  fi

  printf '%s %d\n' "$agent_name" "$$" > "$lock_file"
  return 0
}

worktree_lock_release() {
  local wt_path="$1"
  local lock_file
  lock_file="$(worktree_lock_path "$wt_path")"
  if [[ -f "$lock_file" ]]; then
    local pid
    pid="$(awk '{print $NF}' "$lock_file" 2>/dev/null || true)"
    if [[ "$pid" == "$$" ]]; then
      rm -f "$lock_file"
      return 0
    fi
  fi
  return 1
}
