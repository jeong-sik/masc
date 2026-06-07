(** Keeper Turn Holders — holder diagnostics.

    Runtime turns are no longer admitted here. This module only records holder
    diagnostics while a keeper turn body is executing. *)

type holder_pool =
  | Turn_holder
  | Autonomous_holder
  | Reactive_holder

val holder_pool_to_string : holder_pool -> string

(** Diagnostic: keepers currently holding a slot in each pool, paired
    with how long (in seconds, relative to [now]) they have held it.
    Sorted by descending hold time so the longest-holding peer is first.
    Pure read; no mutation. *)
val turn_holders : now:float -> (string * float) list
val autonomous_holders : now:float -> (string * float) list
val reactive_holders : now:float -> (string * float) list

(** Force-release stale admitted-turn holders for [keeper_name].
    Returns the labels released. *)
val force_release_stale_holder : keeper_name:string -> string list

(** Test-only: TTL used to bound orphaned force-release markers. *)
val force_released_marker_ttl_sec_for_test : float

(** Test-only: count force-release markers still awaiting finalizer. *)
val force_released_marker_count_for_test : unit -> int

(** Test-only: inject a marker without touching live holder rows. *)
val add_force_released_marker_for_test :
  label:holder_pool ->
  keeper_name:string ->
  acquisition_id:int ->
  marked_at:float ->
  unit

(** Test-only: prune expired force-release markers using an injected clock. *)
val purge_force_released_markers_for_test : now:float -> unit

(** Test-only: clear force-release markers between tests. *)
val clear_force_released_markers_for_test : unit -> unit

(** Render a compact holder list such as [[keeper-a/181s, +2 more]]. *)
val format_holders : ?limit:int -> (string * float) list -> string

(** Operator-facing one-line summary of all holder pools. *)
val holders_summary : ?limit:int -> now:float -> unit -> string

(** Force-release the turn holder rows recorded for [keeper_name] in the holder
    table. Returns the [(label, age_sec)] pairs that were released.
    Empty list means nothing was held. *)
val force_release_holder_for : keeper_name:string -> (string * float) list

(** Test-only: inject a callback immediately after an acquire flag is set
    and before the diagnostic holder row is recorded. *)
val set_after_acquire_flag_hook_for_test :
  (label:string -> keeper_name:string -> unit) option -> unit

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

type turn_holder_state

type turn_holder_control =
  { is_held : unit -> bool
  }

val run_with_recorded_holder :
  runtime_profile:string ->
  keeper_name:string ->
  channel:Keeper_world_observation.keeper_cycle_channel ->
  channel_label:string ->
  started_at:float ->
  (semaphore_wait_ms:int -> holder_control:turn_holder_control -> 'a) ->
  'a

(** Holder-diagnostic wrapper. This records holder rows around the callback; it
    does not acquire runtime capacity or a semaphore. *)
val with_recorded_turn_holder :
  ?runtime_profile:string ->
  keeper_name:string ->
  channel:Keeper_world_observation.keeper_cycle_channel ->
  (semaphore_wait_ms:int -> 'a) ->
  'a

(** Like [with_recorded_turn_holder] but exposes [holder_control] to the callback. *)
val with_recorded_turn_holder_control :
  ?runtime_profile:string ->
  keeper_name:string ->
  channel:Keeper_world_observation.keeper_cycle_channel ->
  (semaphore_wait_ms:int -> holder_control:turn_holder_control -> 'a) ->
  'a
