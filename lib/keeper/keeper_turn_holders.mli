(** Keeper Turn Slot — holder diagnostics and compatibility helpers.

    Per-keeper turn isolation, global capacity, and fleet stop admission live
    in {!Keeper_turn_admission}. This module records holder diagnostics after
    admission grants a token. Production turn execution does not acquire
    admission through this module.

    The autonomous FIFO queue has been removed from production admission.
    Reactive/autonomous channel capacity and holder diagnostics are preserved
    after the central admission gate grants a token. *)

(** {1 SSOT Types} *)
include module type of struct
  include Keeper_turn_admission_types
end

(** {1 Own-module types and vals} *)

(** Configured global turn admission budget. *)
val keeper_turn_throttle_limit : int

(** Effective throttle limit after applying the 2x TOML cap (issue #17192). *)
val effective_turn_throttle_limit : int

(** Which configuration layer supplied the effective throttle limit.
    Re-exported for compatibility; the SSOT lives in
    {!Keeper_turn_admission}. *)
type throttle_source = Keeper_turn_admission.throttle_source =
  | Env_override
  | Toml
  | Default

val keeper_turn_throttle_source : throttle_source
val throttle_source_to_string : throttle_source -> string

(** Test-only: resolve a keeper turn concurrency env var through the same
    test-executable isolation gate used at module initialization. *)
val turn_concurrency_int_of_env_default_for_test :
  string -> default:int -> min_v:int -> max_v:int -> int

(** Wall-clock cap while a keeper waits for turn admission.
    Derived from [MASC_KEEPER_SEMAPHORE_WAIT_TIMEOUT_SEC]. *)
val semaphore_wait_timeout_sec : float

(** Test-only admission capacity snapshots. [turn_*] reports the shared global
    budget; reactive/autonomous helpers report their channel-specific budget
    after applying the shared global cap. *)
val turn_semaphore_value_for_test : unit -> int
val autonomous_turn_semaphore_value_for_test : unit -> int
val reactive_turn_semaphore_value_for_test : unit -> int

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

(** Test-only: inject a marker without touching the admission token. *)
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

(** Force-release the admitted turn recorded for [keeper_name] in the holder
    table. Returns the [(label, age_sec)] pairs that were released.
    Empty list means nothing was held.

    Also releases the global-admission token consumed by that holder. *)
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

(** Test-only: expose global inflight count. *)
val global_inflight_for_test : unit -> int

(** Test-only: expose global turn limit. *)
val global_turn_limit_for_test : unit -> int

(** Test-only compatibility model for removed autonomous queue behavior. These
    helpers are not used by production admission. *)
val reset_autonomous_turn_queue_for_test : unit -> unit
val autonomous_waiter_snapshot_for_test : unit -> string list
val enqueue_autonomous_waiter_for_test : ?runtime_id:string -> string -> int
val drop_autonomous_waiter_for_test : int -> unit
val autonomous_waiter_head_ticket_for_test : runtime_id:string -> int option
val autonomous_wait_queue_depth_for_test : unit -> int
val wait_for_autonomous_queue_head_for_test :
  ?runtime_id:string ->
  keeper_name:string ->
  ticket:int ->
  started_at:float ->
  unit ->
  (unit, [> `Semaphore_wait_timeout of semaphore_wait_timeout ]) result
val fairness_delay_sec_at : now:float -> keeper_name:string -> float
val record_autonomous_completion_at_for_test : keeper_name:string -> ts:float -> unit
val reset_autonomous_completion_for_test : unit -> unit

type turn_holder_state

type turn_holder_control =
  { is_held : unit -> bool
  }

val run_with_admission_token :
  runtime_profile:string ->
  keeper_name:string ->
  channel:Keeper_world_observation.keeper_cycle_channel ->
  channel_label:string ->
  admission_token:Keeper_turn_admission.token ->
  started_at:float ->
  (semaphore_wait_ms:int -> holder_control:turn_holder_control -> 'a) ->
  'a

(** Holder-diagnostic facade backed by {!Keeper_turn_admission.acquire_turn}.
    This records holder rows after central admission grants a token; it does not
    own a separate production semaphore. *)
val with_recorded_turn_admission :
  ?base_path:string ->
  ?runtime_profile:string ->
  keeper_name:string ->
  channel:Keeper_world_observation.keeper_cycle_channel ->
  (semaphore_wait_ms:int -> 'a) ->
  ( 'a
  , [> `Semaphore_wait_timeout of semaphore_wait_timeout
    | `Turn_admission_rejected of Keeper_turn_admission.rejection
    ] )
  result

(** Like [with_recorded_turn_admission] but exposes [holder_control] to the callback. *)
val with_recorded_turn_admission_control :
  ?base_path:string ->
  ?runtime_profile:string ->
  keeper_name:string ->
  channel:Keeper_world_observation.keeper_cycle_channel ->
  (semaphore_wait_ms:int -> holder_control:turn_holder_control -> 'a) ->
  ( 'a
  , [> `Semaphore_wait_timeout of semaphore_wait_timeout
    | `Turn_admission_rejected of Keeper_turn_admission.rejection
    ] )
  result

(** Test-only wrappers. *)
val with_recorded_turn_admission_for_test :
  ?runtime_profile:string ->
  keeper_name:string ->
  channel:Keeper_world_observation.keeper_cycle_channel ->
  (semaphore_wait_ms:int -> 'a) ->
  ( 'a
  , [> `Semaphore_wait_timeout of semaphore_wait_timeout
    | `Turn_admission_rejected of Keeper_turn_admission.rejection
    ] )
  result

val with_recorded_turn_admission_control_for_test :
  ?runtime_profile:string ->
  keeper_name:string ->
  channel:Keeper_world_observation.keeper_cycle_channel ->
  (semaphore_wait_ms:int -> holder_control:turn_holder_control -> 'a) ->
  ( 'a
  , [> `Semaphore_wait_timeout of semaphore_wait_timeout
    | `Turn_admission_rejected of Keeper_turn_admission.rejection
    ] )
  result
