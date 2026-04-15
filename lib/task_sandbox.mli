(** Task_sandbox — Worktree-based per-task filesystem isolation.

    Wraps [Coord_worktree] to provide a higher-level sandbox lifecycle:
    create sandbox, run work, collect diff, cleanup.

    A sandbox consists of:
    - A git worktree branched from main
    - A read-only symlink to [.masc/] for room state access
    - An execution scope constraining what the agent may do *)

(** A sandbox created for a single task. *)
type sandbox = {
  task_id : string;
  worktree_path : string;
  branch_name : string;
  execution_scope : Worker_types.execution_scope;
  created_at : float;
}

val create :
  config:Coord_utils_backend_setup.config ->
  task_id:string ->
  ?scope:Worker_types.execution_scope ->
  ?base_branch:string ->
  agent_name:string ->
  unit ->
  (sandbox, string) result
(** Create sandbox: worktree + [.masc/] symlink + scope config.
    Returns [Ok sandbox] on success or [Error reason] on failure. *)

val cleanup :
  config:Coord_utils_backend_setup.config ->
  agent_name:string ->
  sandbox ->
  (string list, string) result
(** Diff worktree against base branch, then remove worktree.
    Returns [Ok changed_files] on success. *)

val with_sandbox :
  config:Coord_utils_backend_setup.config ->
  task_id:string ->
  ?scope:Worker_types.execution_scope ->
  ?base_branch:string ->
  agent_name:string ->
  (sandbox -> 'a) ->
  ('a * string list, string) result
(** Create sandbox, run function, cleanup.
    Returns [(result, changed_files)] on success.
    Cleanup runs even if [f] raises (via [Fun.protect]). *)

val changed_files :
  sandbox ->
  string list
(** List files changed in the worktree relative to the branch base.
    Returns empty list on error. *)
