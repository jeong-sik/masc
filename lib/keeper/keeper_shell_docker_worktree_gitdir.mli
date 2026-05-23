(** Container-aware git worktree gitdir path rewriter.

    [git worktree add] stamps absolute repo paths into worktree
    gitfiles and into [<main>/.git/worktrees/<name>/gitdir].  When
    the host root and the container root differ, those stamps are
    invalid inside the wrong root.  [prepare] applies the host->
    container rewrite before the container starts; [repair] reverses
    it after the container exits. *)

(** Enumerate all gitfile/gitdir candidates under
    [<host_root>/repos/*/{.worktrees/*/.git, .git/worktrees/*/gitdir}]. *)
val candidates : host_root:string -> string list

(** Rewrite [container_root] -> [host_root] in each candidate.  Returns
    the count of files actually modified. *)
val repair : host_root:string -> container_root:string -> int

(** Rewrite [host_root] -> [container_root] in each candidate.  Returns
    the count of files actually modified. *)
val prepare : host_root:string -> container_root:string -> int

(** [prepare] when [git_creds_enabled] and the command targets [git] or [gh].
    Logs at info level when any paths were rewritten. *)
val prepare_conditional :
  git_creds_enabled:bool ->
  cmd:string ->
  host_root:string ->
  container_root:string ->
  keeper_name:string ->
  int

(** [repair] when [git_creds_enabled] is true.  Logs at info level when
    any paths were restored. *)
val restore_and_log :
  git_creds_enabled:bool ->
  host_root:string ->
  container_root:string ->
  keeper_name:string ->
  unit
