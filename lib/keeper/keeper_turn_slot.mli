(** Keeper Turn Slot — runtime-concurrent budget plus per-keeper turns.

    Each keeper first acquires its own slot, preserving per-keeper turn
    order, then consumes the shared runtime-concurrent budget. This keeps a
    stuck keeper from blocking a different keeper's private slot while still
    enforcing one global runtime concurrency budget.

    The autonomous FIFO queue and reactive/autonomous semaphores have been
    removed from production admission. Reactive/autonomous holder accessors
    are preserved as diagnostic channel labels for the single per-keeper
    slot. *)

(** {1 SSOT Types} *)
include module type of struct
  include Keeper_turn_slot_types
end

(** {1 Own-module types and vals} *)

(** Configured runtime-concurrent budget. *)
val keeper_turn_throttle_limit : int

(** Effective throttle limit after applying the 2x TOML cap (issue #17192). *)
val effective_turn_throttle_limit : int

(** Which configuration layer supplied the effective throttle limit. *)
type throttle_source =
  | Env_override
  | Toml
  | Default

val keeper_turn_throttle_source : throttle_source
val throttle_source_to_string : throttle_source -> string

(** Test-only: resolve a keeper turn concurrency env var through the same
    test-executable isolation gate used at module initialization. *)
val turn_concurrency_int_of_env_default_for_test :
  string -> default:int -> min_v:int -> max_v:int -> int

(** Wall-clock cap when a keeper waits on its own previous turn slot.
    Derived from [MASC_KEEPER_SEMAPHORE_WAIT_TIMEOUT_SEC]. *)
val semaphore_wait_timeout_sec : float

(** Test-only runtime-concurrent capacity snapshots. Reactive/autonomous
    helpers report the same shared budget because those legacy pool-specific
    gates no longer exist. *)
val turn_semaphore_value_for_test : unit -> int
val autonomous_turn_semaphore_value_for_test : unit -> int
val reactive_turn_semaphore_value_for_test : unit -> int

(** Diagnostic: keepers currently holding a slot in each pool, paired
    with how long (in seconds, relative to [now]) they have held it.
    Sorted by descending hold time so the longest-holding peer is first.
    Pure read; no mutation. *)
val turn_slot_holders : now:float -> (string * float) list
val autonomous_slot_holders : now:float -> (string * float) list
val reactive_slot_holders : now:float -> (string * float) list

(** Force-release stale holders for [keeper_name]. Returns the labels released. *)
val force_release_stale_holder : keeper_name:string -> string list

(** Test-only: TTL used to bound orphaned force-release markers. *)
val force_released_marker_ttl_sec_for_test : float

(** Test-only: count force-release markers still awaiting finalizer. *)
val force_released_marker_count_for_test : unit -> int

(** Test-only: inject a marker without touching inflight counter. *)
val add_force_released_marker_for_test :
  label:slot_pool ->
  keeper_name:string ->
  acquisition_id:int ->
  marked_at:float ->
  unit

(** Test-only: prune expired force-release markers using an injected clock. *)
val purge_force_released_markers_for_test : now:float -> unit

(** Test-only: clear force-release markers between tests. *)
val clear_force_released_markers_for_test : unit -> unit

(** Render a compact holder list such as [[keeper-a/181s, +2 more]]. *)
val format_slot_holders : ?limit:int -> (string * float) list -> string

(** Operator-facing one-line summary of all holder pools. *)
val slot_holders_summary : ?limit:int -> now:float -> unit -> string

(** Force-release the per-keeper slot recorded for [keeper_name] in the holder
    table. Returns the [(label, age_sec)] pairs that were released.
    Empty list means nothing was held.

    Also returns the shared runtime-concurrent budget token consumed by that
    holder. *)
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

(** Test-only: expose global inflight count (diagnostic gauge, no admission limit). *)
val global_inflight_for_test : unit -> int

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

type keeper_turn_slot_state

type keeper_turn_slot_control =
  { is_held : unit -> bool
  }

(** Main entry point. Acquires the keeper's own slot, then consumes the
    shared runtime-concurrent budget before running [f]. *)
val with_keeper_turn_slot :
  ?runtime_profile:string ->
  keeper_name:string ->
  channel:Keeper_world_observation.keeper_cycle_channel ->
  (semaphore_wait_ms:int -> 'a) ->
  ('a, [> `Semaphore_wait_timeout of semaphore_wait_timeout ]) result

(** Like [with_keeper_turn_slot] but exposes [slot_control] to the callback. *)
val with_keeper_turn_slot_control :
  ?runtime_profile:string ->
  keeper_name:string ->
  channel:Keeper_world_observation.keeper_cycle_channel ->
  (semaphore_wait_ms:int -> slot_control:keeper_turn_slot_control -> 'a) ->
  ('a, [> `Semaphore_wait_timeout of semaphore_wait_timeout ]) result

(** Test-only wrappers. *)
val with_keeper_turn_slot_for_test :
  ?runtime_profile:string ->
  keeper_name:string ->
  channel:Keeper_world_observation.keeper_cycle_channel ->
  (semaphore_wait_ms:int -> 'a) ->
  ('a, [> `Semaphore_wait_timeout of semaphore_wait_timeout ]) result

val with_keeper_turn_slot_control_for_test :
  ?runtime_profile:string ->
  keeper_name:string ->
  channel:Keeper_world_observation.keeper_cycle_channel ->
  (semaphore_wait_ms:int -> slot_control:keeper_turn_slot_control -> 'a) ->
  ('a, [> `Semaphore_wait_timeout of semaphore_wait_timeout ]) result
