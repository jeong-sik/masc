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
