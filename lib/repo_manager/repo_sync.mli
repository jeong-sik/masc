open Repo_manager_types

type advance_outcome =
  | Advanced of { behind : int }
      (** Working tree fast-forwarded onto [origin/<default_branch>];
          [behind] is the commit count covered by the move. *)
  | Already_current
      (** HEAD already contains [origin/<default_branch>]. *)
  | Skipped_dirty of { staged : int; unstaged : int; conflicted : int }
      (** Tracked local modifications present — the move was skipped to
          preserve them (RFC-0210 work-preserving rule). *)
  | Skipped_not_on_default_branch of { current : string }
      (** The clone has a non-default branch (or detached HEAD, reported as
          ["HEAD"]) checked out — the move was skipped. *)
  | Fast_forward_refused of { behind : int; reason : string }
      (** [git merge --ff-only] declined the move (divergent history or an
          untracked file would be overwritten); the tree is unchanged. *)
  | Advance_inspect_failed of { reason : string }
      (** A read-only git inspection (rev-list / rev-parse / status) failed;
          the tree is unchanged. *)

val advance_outcome_label : advance_outcome -> string
(** Stable wire/log label for each [advance_outcome] constructor. *)

val sync_repository :
  base_path:string -> repository -> (advance_outcome, string) result
(** [sync_repository ~base_path repo] fetches the repository, then advances
    the checked-out default branch to [origin/<default_branch>]
    (work-preserving; see {!advance_outcome}). Status becomes [Active] on
    fetch success and [Error msg] on fetch/clone failure. Advance-stage
    skips and refusals are typed outcomes, not errors, because the refs are
    current after a successful fetch. *)

val should_sync : repository -> now:int64 -> bool
(** [should_sync repo ~now] returns [true] if [repo.auto_sync] is enabled and
    [now - repo.updated_at] exceeds [repo.sync_interval] seconds. *)

val sync_all :
  base_path:string ->
  now:int64 ->
  ((repository * advance_outcome) list, string) result
(** [sync_all ~base_path ~now] loads all repositories, filters those that
    should_sync, syncs each one, and returns the successfully synced
    repositories paired with their working-tree advance outcome. *)
