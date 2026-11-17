(** The one place a Keeper turn gets its number (#52839).

    The Keeper Owner advances and persists [runtime.last_turn_id] before
    [allocate] returns, so the number is spent before anything is written
    under it. A turn that ends without its usage commit (process exit,
    cancellation, commit failure) therefore never hands its number to the
    next turn. *)

val allocate :
  config:Workspace.config -> keeper_name:string -> (int, Agent_core.Error.t) result
(** [Error] carries the Owner's refusal as an I/O failure on the Keeper's
    metadata; no turn runs without a number. *)
