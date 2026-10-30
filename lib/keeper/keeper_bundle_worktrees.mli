(** Remove the git worktrees a dissolved keeper's clones registered.

    A keeper's playground bundle (Docker: [.masc/playground/docker/<keeper>],
    microVM and remote SSH: [.masc/playground/<keeper>], see
    {!Keeper_sandbox_config.host_root_rel_of_profile}) holds its clones under
    [repos/<id>], and the worktrees those clones register stay on disk after
    the keeper is gone. Shutdown finalization calls
    {!remove_keeper_worktrees} for a removed keeper only: it knows which
    keeper is gone, so nothing here guesses ownership from a registry scan.

    Only what [git worktree list --porcelain] of those clones names is
    removed, through [git worktree remove --force]. The keeper is gone for
    good, so uncommitted changes in its worktrees go with it; [--force] is
    also what stops git from running [git status] inside the worktree, which
    would execute the clone's own [filter.<name>.clean] and [.process]
    commands on the host. A locked worktree still refuses (it needs [--force]
    twice) and stays, named in a warning. A worktree whose resolved path is
    outside the bundle is reported, never removed. The clones themselves are
    kept. *)

val worktree_paths_of_porcelain
  :  repo_path:string
  -> string
  -> (string list, string) result
(** Linked worktree paths from one [git worktree list --porcelain] payload:
    the first line of every block, minus the clone's own checkout
    ([repo_path], matched literally or after [Unix.realpath]). A block without
    a [worktree] line, or a payload naming no worktrees at all, rejects the
    whole snapshot: an unreadable answer never authorizes a removal. *)

val worktree_list_argv : repo_path:string -> string list

val worktree_remove_argv : repo_path:string -> worktree_path:string -> string list

val within_bundle : bundle_root:string -> string -> (unit, string) result
(** Both sides are resolved with [Unix.realpath] and the path must equal
    [bundle_root] or sit under it. An escape or an unresolvable path is
    [Error]: removal needs proof of ownership, not absence of proof. *)

type repo_outcome =
  { removed : string list
  ; failed : (string * string) list
  ; skipped : string
  }

val prune_repo_worktrees
  :  run_argv:(timeout_sec:float -> string list -> Unix.process_status * string)
  -> timeout_sec:float
  -> repo_path:string
  -> bundle_root:string
  -> repo_outcome
(** List one clone's worktrees and remove every linked one inside
    [bundle_root]. A listing that fails or does not parse is reported under
    [skipped] and removes nothing; paths outside the bundle are reported
    under [skipped] and never removed; removals git refuses (a locked
    worktree) land in [failed] and do not stop the rest. *)

val remove_keeper_worktrees
  :  run_argv:(timeout_sec:float -> string list -> Unix.process_status * string)
  -> timeout_sec:float
  -> base_path:string
  -> keeper_name:string
  -> profile:Keeper_sandbox_config.sandbox_profile
  -> (string * repo_outcome) list
(** {!prune_repo_worktrees} for every clone under the keeper's bundle,
    paired with the clone's path. A bundle without a [repos] directory has
    nothing to remove and sends no command. *)

val log_outcomes : keeper_name:string -> (string * repo_outcome) list -> unit
(** One info line per clone that removed something, one warning per
    worktree that stayed and per clone that was skipped. *)
