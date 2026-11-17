(** The one place a Keeper turn gets its number (#52839).

    The Keeper Owner advances and persists [runtime.last_turn_id] before
    [allocate] returns, so the number is spent before anything is written
    under it. A turn that ends without its usage commit (process exit,
    cancellation, commit failure) therefore never hands its number to the
    next turn. *)

type error =
  | Keeper_absent of Keeper_owner_registry.command_error
      (** No Keeper by that name: the inventory has no Owner for it, or the
          Owner holds no meta ([Meta_missing]). The caller named something
          absent; no turn ran. *)
  | Owner_refused of Keeper_owner_registry.command_error
      (** The Keeper exists, or may exist, and its Owner could not spend a
          number. *)

val allocate :
  config:Workspace.config -> keeper_name:string -> (int, error) result
(** No turn runs without a number. *)

val to_core_error :
  config:Workspace.config -> keeper_name:string -> error -> Agent_core.Error.t
(** The refusal as an I/O failure on the Keeper's metadata, for turn paths
    that report runtime failures as [Agent_core.Error.t]. *)
