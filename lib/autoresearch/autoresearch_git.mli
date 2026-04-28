(** Autoresearch_git — git invocation helpers for the autoresearch
    loop's managed worktree.

    Wraps the small subset of git commands the autoresearch driver
    needs (commit/restore/reset/tag/branch/worktree). Most callers
    interact with the per-action functions and the
    {!is_in_git_repo} predicate; {!run_git_with_status} and
    {!run_capture_lines} are exposed because {!Autoresearch}
    re-exports them as part of its public surface.

    Functions returning [unit] (e.g. {!git_reset_last},
    {!git_restore_head}, {!git_tag_best}) silently no-op when [workdir]
    is not inside a git repo or when the underlying git command
    fails. The [Result]-returning variants surface errors verbatim. *)

(** {1 Status / introspection} *)

val is_in_git_repo : string -> bool
(** [true] iff [<dir>] (or any ancestor) contains a [.git] entry.
    Pure filesystem walk; does not invoke [git]. *)

val run_git_with_status :
  ?timeout_sec:float ->
  workdir:string ->
  string list ->
  Unix.process_status * string
(** Run [git -C <workdir> <argv>] through the exec gate; returns the
    raw exit status and combined stdout/stderr. Default timeout 30s. *)

val run_capture_lines :
  workdir:string ->
  ?timeout_sec:float ->
  string list ->
  Unix.process_status * string list
(** Run [git -C <workdir> <argv>] and split stdout into non-empty
    lines. Default timeout 30s. *)

val git_top_level : workdir:string -> (string, string) result
(** [git rev-parse --show-toplevel] in [workdir]. *)

val git_current_branch : workdir:string -> string option
(** [git rev-parse --abbrev-ref HEAD], or [None] outside a repo. *)

val git_head_short : workdir:string -> string option
(** Short HEAD SHA from [git rev-parse --short HEAD], or [None]. *)

val git_is_dirty : workdir:string -> bool
(** [true] iff [git status --porcelain] reports any tracked changes. *)

(** {1 Mutating actions (no-op outside a repo)} *)

val git_restore_head :
  workdir:string -> unit
(** [git restore --source=HEAD --worktree -- .] — discard all local
    edits. *)

val git_reset_last :
  workdir:string -> unit
(** [git reset --soft HEAD~1]. *)

val git_commit :
  workdir:string -> message:string -> (string option, string) result
(** Stages tracked changes ([git add --update]), then [git commit -m
    message]. Returns [Ok (Some sha)] for the new commit, [Ok None] if
    there was nothing to commit, [Error msg] otherwise. *)

val git_commit_cycle :
  workdir:string ->
  cycle:int ->
  hypothesis:string ->
  baseline:float ->
  (string option, string) result
(** Convenience wrapper around {!git_commit} that builds the canonical
    autoresearch cycle commit message
    [\[autoresearch\] cycle <n>: <hypothesis> (baseline=<b>)]. The
    hypothesis is sanitized: control characters collapse to single
    spaces and surrounding whitespace is trimmed. *)

val git_tag_best :
  workdir:string -> cycle:int -> score:float -> unit
(** Force-create a tag [ar-best-c<cycle>-<score>] on the current HEAD.
    Silently swallows tag-creation errors. *)

(** {1 Managed worktree lifecycle} *)

val managed_branch_name : string -> string
(** [autoresearch/<loop_id>] — branch name used by
    {!prepare_managed_worktree}. *)

val prepare_managed_worktree :
  base_path:string ->
  source_workdir:string ->
  loop_id:string ->
  (string * string * string list, string) result
(** [Ok (workdir, repo_root, warnings)] on success; [Error msg] when
    [git_top_level] fails or the target [workdir] already exists.
    [warnings] flags [source_workdir_dirty] and non-trunk source
    branches. *)

val local_branch_exists : repo_root:string -> string -> bool
(** [true] iff [refs/heads/<branch>] exists under [repo_root]. *)

val cleanup_managed_worktree :
  base_path:string ->
  source_workdir:string ->
  loop_id:string ->
  (bool * bool, string) result
(** Removes the autoresearch managed worktree directory and the
    associated branch (if any). Returns [Ok (workdir_removed,
    branch_removed)] flagging whether each artifact existed and was
    deleted; [Error] only when [git_top_level source_workdir] fails. *)
