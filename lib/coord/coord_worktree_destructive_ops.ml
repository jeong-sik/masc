(** Coord Worktree - Destructive filesystem / git operations.

    Single landing place for every operation that deletes or force-mutates
    on-disk state inside the worktree subsystem.  Grouping is intentional:
    a single grep of [lib/coord/coord_worktree_destructive_ops.ml] (or a
    grep for [Coord_worktree_destructive_ops]) must enumerate every
    destructive entry point used by [Coord_worktree].

    Behaviour mirrors the inline call sites from the pre-split
    [coord_worktree.ml]; this module adds no new safety checks and removes
    none.  Callers stay responsible for higher-level guards
    (worktree mutation lock, idempotency, etc.).

    Stage 06, godfile decomposition plan 2026-05-18. *)

(** Recursively remove [path]; silently no-op when [path] is missing.

    Used after a failed sandbox clone provisioning or worktree creation to
    avoid leaving a half-populated directory behind.  Best-effort: any
    underlying [Unix.Unix_error] is swallowed so a single permission
    glitch does not mask the original failure being reported upstream. *)
let rec rm_rf path =
  if Coord_worktree_paths.safe_file_exists path then
    if Coord_worktree_paths.safe_is_dir path then begin
      (try Sys.readdir path with Sys_error _ -> [||])
      |> Array.iter (fun entry -> rm_rf (Filename.concat path entry));
      (try Unix.rmdir path with Unix.Unix_error _ -> ())
    end else
      try Unix.unlink path with Unix.Unix_error _ -> ()

(** Run [git -C root worktree remove <worktree_path>] and return the exit
    code (128 for signaled/stopped).  This is the destructive step in
    [worktree_remove_r]; it removes the worktree's on-disk checkout and
    its entry in the parent repo's [worktrees/] metadata. *)
let git_worktree_remove ~root ~worktree_path =
  Coord_worktree_exec.run_argv_exit
    [ "git"; "-C"; root; "worktree"; "remove"; worktree_path ]

(** Run [git -C root branch -D <branch_name>] and return the exit code.
    Uses [-D] (capital) to force-delete an unmerged branch, matching the
    pre-split behaviour so we never strand a worktree's branch after the
    worktree itself was removed. *)
let git_branch_force_delete ~root ~branch_name =
  Coord_worktree_exec.run_argv_exit
    [ "git"; "-C"; root; "branch"; "-D"; branch_name ]

(** Run [git -C root worktree prune] and return the exit code.  Cleans up
    stale worktree entries whose checkouts have already been deleted. *)
let git_worktree_prune ~root =
  Coord_worktree_exec.run_argv_exit
    [ "git"; "-C"; root; "worktree"; "prune" ]
