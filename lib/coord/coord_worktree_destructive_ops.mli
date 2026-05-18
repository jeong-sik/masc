(** Destructive filesystem / git operations used by the worktree
    subsystem.

    Every entry point in this module may delete or force-mutate on-disk
    state.  Centralised so a single grep of this file enumerates the
    full destructive surface; no other module in [masc_coord] should
    invoke [rm -rf]-class commands or [git worktree remove] /
    [git branch -D] / [git worktree prune].

    Stage 06, godfile decomposition plan 2026-05-18. *)

val rm_rf : string -> unit
(** Recursively remove [path]; silently no-op when [path] is missing.
    Best-effort: per-entry [Unix.Unix_error] is swallowed. *)

val git_worktree_remove : root:string -> worktree_path:string -> int
(** [git -C root worktree remove <worktree_path>].  Returns the exit code
    (128 for signaled/stopped). *)

val git_branch_force_delete : root:string -> branch_name:string -> int
(** [git -C root branch -D <branch_name>].  Force-deletes the branch
    even if unmerged.  Returns the exit code. *)

val git_worktree_prune : root:string -> int
(** [git -C root worktree prune].  Cleans stale worktree metadata.
    Returns the exit code. *)
