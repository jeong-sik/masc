(** Lazy repair for current-task keeper worktrees.

    The claim hook eagerly provisions a task worktree when it has enough
    repository context, but keeper shell calls can still arrive with a cwd or
    [git -C] target under [repos/<repo>/.worktrees/<keeper>-<task>] after the
    directory was never created or was removed.  This module recognizes only
    the current task's canonical worktree path and asks {!Task_sandbox} to
    create that worktree before the path validator rejects it as a missing
    directory. *)

type ensure_outcome =
  | Already_present
  | Created
  | Not_current_task_worktree

val ensure_path :
  site:string ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  path:string ->
  (ensure_outcome, string) result
(** Ensure [path] when it is exactly the current task worktree directory.
    Non-matching paths return [Ok Not_current_task_worktree] so the normal
    path validator can render the final error. *)

val ensure_command_existing_dirs :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  cwd:string ->
  cmd:string ->
  (unit, string) result
(** Inspect [cmd] for existing-directory path requirements such as
    [git -C <dir>] and lazily repair matching current-task worktrees relative
    to [cwd]. *)
