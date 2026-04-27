(** Coord_git — MASC git worktree operations.

    Public surface for {!Coord_git.ml}.  Provides per-agent / per-task
    worktree isolation for parallel work.  All git invocations are
    argv-based (no shell) to avoid injection.  See issue #10751 for
    the broader [coord/] [.mli] coverage push.

    Threading: every function below shells out via [Process] /
    [Masc_exec] with bounded timeouts.  No coord-level lock is
    acquired here, so callers may invoke concurrently as long as the
    underlying git repo permits parallel reads.  [create] and [remove]
    mutate the worktree set and assume git's own locking.

    Naming: worktree paths and branch names are derived from
    {!Playground_paths.worktree_dir_name} and
    {!Playground_paths.worktree_branch_name}; this module does not
    own the naming scheme. *)

(** [path_is_masc_worktree p] reports whether [p] sits under the MASC
    [.worktrees/] sentinel.  Substring check; no [Re] compile per call. *)
val path_is_masc_worktree : string -> bool

(** [has_git_marker path] returns [true] if [path] (or any ancestor)
    contains a [.git] entry.  Used as a fast-fail guard before calling
    git subprocesses on non-repo directories. *)
val has_git_marker : string -> bool

(** [git_root ~base_path] resolves the git toplevel containing
    [base_path] via [git rev-parse --show-toplevel].  Returns [None]
    when the path is outside any git repo or git fails. *)
val git_root : base_path:string -> string option

(** [is_git_repo ~base_path] is [true] when {!git_root} succeeds. *)
val is_git_repo : base_path:string -> bool

(** [remote_branch_exists root branch] queries [origin/<branch>] via
    [git rev-parse --verify].  No fetch is performed; the answer
    reflects whatever the local refs cache holds. *)
val remote_branch_exists : string -> string -> bool

(** [origin_head_branch root] returns the branch [origin/HEAD]
    resolves to (typically [main] or [master]).  [None] when
    [origin/HEAD] is not set. *)
val origin_head_branch : string -> string option

(** [resolve_base_branch root requested] picks the actual base ref to
    create a new worktree from:
    - returns [Ok (requested, None)] if [origin/requested] exists
    - otherwise falls back to [origin/HEAD] / [main] / [master] in
      order and returns [Ok (resolved, Some requested)]
    - returns [Error _] when no candidate exists. *)
val resolve_base_branch :
  string -> string ->
  (string * string option, Types.masc_error) result

(** [create ~base_path ~agent_name ~task_id ~base_branch] adds a new
    worktree at [<root>/.worktrees/<agent>-<task>] tracking a fresh
    branch from [origin/<base_branch>] (after a mandatory [git fetch
    origin] under the configured timeout — #9587).  Returns a human-
    readable success message or an [IoError] describing the first
    git command that failed. *)
val create :
  base_path:string ->
  agent_name:string ->
  task_id:string ->
  base_branch:string ->
  string Types.masc_result

(** [remove ~base_path ~agent_name ~task_id] removes the worktree and
    deletes its tracking branch.  Returns success with any non-fatal
    warnings (branch delete or prune returning non-zero are reported
    in the message but do not fail the operation). *)
val remove :
  base_path:string ->
  agent_name:string ->
  task_id:string ->
  string Types.masc_result

(** [list ~base_path] returns a JSON object describing every worktree
    in the repository:
    {v
    { "worktrees": [ { "path": ..., "branch": ..., "is_masc": bool } ],
      "count":     int,
      "masc_hint": string }
    v}
    Errors surface as [{ "error": "Not a git repository" }]. *)
val list : base_path:string -> Yojson.Safe.t

(** [get_info ~base_path ~agent_name ~task_id] returns
    [Some (worktree_path, branch_name)] when the corresponding
    worktree directory exists, [None] otherwise.  Does not invoke git;
    a pure filesystem check. *)
val get_info :
  base_path:string ->
  agent_name:string ->
  task_id:string ->
  (string * string) option
