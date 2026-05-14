# Shared safety guards for worktree cleanup scripts.
#
# The stale-worktree incident in #11040 showed that a merged/stale worktree can
# still be operationally pinned by a tmux pane, a running server command, or a
# LaunchAgent plist. Cleanup scripts should treat those references as a hard
# skip signal.

_WORKTREE_CLEANUP_RUNTIME_REFS_LOADED=0
_WORKTREE_CLEANUP_RUNTIME_REFS=""

worktree_cleanup_append_refs() {
  local text="$1"
  [ -z "$text" ] && return 0
  _WORKTREE_CLEANUP_RUNTIME_REFS="${_WORKTREE_CLEANUP_RUNTIME_REFS}${text}"$'\n'
}

worktree_cleanup_load_runtime_refs() {
  [ "$_WORKTREE_CLEANUP_RUNTIME_REFS_LOADED" -eq 1 ] && return 0
  _WORKTREE_CLEANUP_RUNTIME_REFS_LOADED=1

  if command -v tmux >/dev/null 2>&1; then
    worktree_cleanup_append_refs "$(tmux list-panes -a -F '#{pane_current_path}' 2>/dev/null || true)"
    worktree_cleanup_append_refs "$(tmux list-panes -a -F '#{pane_start_path}' 2>/dev/null || true)"
  fi

  if command -v ps >/dev/null 2>&1; then
    worktree_cleanup_append_refs "$(ps -axww -o command= 2>/dev/null || true)"
  fi

  local dir file home_dir
  home_dir="${HOME:-}"
  for dir in "$home_dir/Library/LaunchAgents" "/Library/LaunchAgents" "/Library/LaunchDaemons"; do
    [ -d "$dir" ] || continue
    for file in "$dir"/*.plist; do
      [ -e "$file" ] || continue
      worktree_cleanup_append_refs "$(cat "$file" 2>/dev/null || true)"
    done
  done
}

worktree_cleanup_is_runtime_referenced() {
  local wt_path="$1"
  worktree_cleanup_load_runtime_refs
  [ -n "$_WORKTREE_CLEANUP_RUNTIME_REFS" ] || return 1
  printf '%s\n' "$_WORKTREE_CLEANUP_RUNTIME_REFS" | grep -F -- "$wt_path" >/dev/null 2>&1
}
