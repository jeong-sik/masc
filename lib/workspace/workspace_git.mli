(** Workspace_git — bounded git metadata helpers.

    Public surface for {!Workspace_git.ml}.  Keeps only repository metadata
    queries used by workspace and readiness checks.  All git
    invocations are argv-based (no shell) to avoid injection.

    Threading: every function below shells out via [Process] /
    [Masc_exec] with bounded timeouts.  No workspace-level lock is
    acquired here, so callers may invoke concurrently as long as the
    underlying git repo permits parallel reads. *)

(** [has_git_marker path] returns [true] if [path] (or any ancestor)
    contains a [.git] entry.  Used as a fast-fail guard before calling
    git subprocesses on non-repo directories. *)
val has_git_marker : string -> bool

(** [git_root ~base_path] resolves the git toplevel containing
    [base_path] via [git rev-parse --show-toplevel].  Returns [None]
    when the path is outside any git repo or git fails. *)
val git_root : base_path:string -> string option

(** [git_first_line ?timeout_sec ~repo_path args] runs [git -C repo_path args]
    through the workspace git execution wrapper and returns the first non-empty
    stdout line.  Failures raise from the underlying process wrapper; callers
    that treat metadata as optional should catch them explicitly. *)
val git_first_line :
  ?timeout_sec:float -> repo_path:string -> string list -> string option

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

(** [resolve_base_branch root requested] picks an available remote base ref:
    - returns [Ok (requested, None)] if [origin/requested] exists
    - otherwise falls back to [origin/HEAD] / [main] / [master] in
      order and returns [Ok (resolved, Some requested)]
    - returns [Error _] when no candidate exists. *)
val resolve_base_branch :
  string -> string ->
  (string * string option, Masc_domain.masc_error) result
