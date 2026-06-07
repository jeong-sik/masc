(** Keeper Turn Holders — holder diagnostics.

    Runtime turns are no longer admitted here. This module only records holder
    diagnostics while a keeper turn body is executing. *)

type holder_pool =
  | Turn_holder
  | Autonomous_holder
  | Reactive_holder

val holder_pool_to_string : holder_pool -> string

(** Diagnostic: keepers currently recorded in each holder pool, paired
    with how long (in seconds, relative to [now]) they have held it.
    Sorted by descending hold time so the longest-holding peer is first.
    Pure read; no mutation. *)
val turn_holders : now:float -> (string * float) list
val autonomous_holders : now:float -> (string * float) list
val reactive_holders : now:float -> (string * float) list

(** Render a compact holder list such as [[keeper-a/181s, +2 more]]. *)
val format_holders : ?limit:int -> (string * float) list -> string

(** Operator-facing one-line summary of all holder pools. *)
val holders_summary : ?limit:int -> now:float -> unit -> string

(** Provider timeout strike limit and classification. *)
val provider_timeout_strike_limit : int

type provider_timeout_strike_outcome =
  | Provider_timeout_warn
  | Provider_timeout_soft_backoff

val classify_provider_timeout_strike :
  strikes:int -> provider_timeout_strike_outcome

val bump_budget_exhaustion_seeded :
  keeper_name:string -> prior_strikes:int -> int
val bump_budget_exhaustion : keeper_name:string -> int
val reset_budget_exhaustion : keeper_name:string -> unit
val peek_budget_exhaustion_for_test : keeper_name:string -> int
val set_budget_exhaustion_for_test : keeper_name:string -> strikes:int -> unit

(** Holder-diagnostic wrapper. This records holder rows around the callback; it
    does not acquire runtime capacity or a semaphore. *)
val with_recorded_turn_holder :
  keeper_name:string ->
  channel:Keeper_world_observation.keeper_cycle_channel ->
  (holder_wait_ms:int -> 'a) ->
  'a
