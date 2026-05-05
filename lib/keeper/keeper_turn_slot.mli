exception Semaphore_wait_timeout of float

type semaphore_wait_phase =
  | Autonomous_queue_head
  | Autonomous_slot
  | Reactive_slot
  | Turn_slot

val semaphore_wait_phase_to_string : semaphore_wait_phase -> string

type semaphore_wait_timeout = {
  timeout_wait_sec : float;
  timeout_phase : semaphore_wait_phase;
  timeout_autonomous_available : int;
  timeout_reactive_available : int;
  timeout_turn_available : int;
  timeout_queue_depth : int;
  timeout_queue_ahead : int option;
  timeout_holders : (string * float) list;
}

(** Global turn slot cap. Safety ceiling for ALL keeper turns. *)
val keeper_turn_throttle_limit : int

val turn_semaphore : Eio.Semaphore.t
val autonomous_turn_semaphore : Eio.Semaphore.t
val reactive_turn_semaphore : Eio.Semaphore.t

(** Wall-clock cap on [Eio.Semaphore.acquire] when waiting for a keeper
    turn slot. Derived from [MASC_KEEPER_SEMAPHORE_WAIT_TIMEOUT_SEC]. *)
val semaphore_wait_timeout_sec : float

type autonomous_waiter = {
  ticket : int;
  keeper_name : string;
}

(** Test-only reset for the autonomous FIFO wait queue. *)
val reset_autonomous_turn_queue_for_test : unit -> unit

(** Test-only snapshot of keeper names currently queued for an autonomous turn. *)
val autonomous_waiter_snapshot_for_test : unit -> string list

(** Test-only snapshots of the current semaphore availability. *)
val turn_semaphore_value_for_test : unit -> int
val autonomous_turn_semaphore_value_for_test : unit -> int
val reactive_turn_semaphore_value_for_test : unit -> int

(** Diagnostic: keepers currently holding a slot in each pool, paired
    with how long (in seconds, relative to [now]) they have held it.
    Sorted by descending hold time so the longest-holding peer is first
    — that is typically the actual fleet blocker when [turn_available=0]
    starves the rest. Pure read; no mutation.

    [~now] MUST come from {!Time_compat.now}, the same clock source
    used to record [acquired_at] inside this module. Mixing
    [Unix.gettimeofday ()] or any other clock can produce nonsense
    hold-time values (negative, or off by the clock skew). *)
val turn_slot_holders : now:float -> (string * float) list
val autonomous_slot_holders : now:float -> (string * float) list
val reactive_slot_holders : now:float -> (string * float) list

(** Force-release semaphore permits held by [keeper_name] after the watchdog
    has classified the holder as stale. Returns the labels actually released.

    This is intentionally narrower than normal cleanup: it only releases
    holders still present in the diagnostic holder table, and the normal
    [with_keeper_turn_slot] finalizer consumes the same acquisition's
    force-release marker so a late-returning fiber cannot double-release the
    same permit, and a newer keeper generation cannot consume the stale
    predecessor's marker. *)
val force_release_stale_holder : keeper_name:string -> string list

(** Test-only: TTL used to bound orphaned force-release markers left behind
    when a cancelled stale fiber never reaches its finalizer. *)
val force_released_marker_ttl_sec_for_test : float

(** Test-only: count force-release markers still awaiting finalizer
    consumption or expiry pruning. *)
val force_released_marker_count_for_test : unit -> int

(** Test-only: inject a marker without touching semaphores, so marker-retention
    behavior can be exercised without creating a double-release path. *)
val add_force_released_marker_for_test :
  label:string ->
  keeper_name:string ->
  acquisition_id:int ->
  marked_at:float ->
  unit

(** Test-only: prune expired force-release markers using an injected clock. *)
val purge_force_released_markers_for_test : now:float -> unit

(** Test-only: clear force-release markers between tests. *)
val clear_force_released_markers_for_test : unit -> unit

(** Render a compact holder list such as [[keeper-a/181s, +2 more]].
    The input is expected to be sorted longest-first, as returned by the
    holder accessors above. *)
val format_slot_holders : ?limit:int -> (string * float) list -> string

(** Operator-facing one-line summary of all holder pools. *)
val slot_holders_summary : ?limit:int -> now:float -> unit -> string

(** Test-only FIFO queue primitives for autonomous fairness regression tests. *)
val enqueue_autonomous_waiter_for_test : string -> int
val drop_autonomous_waiter_for_test : int -> unit

(** Test-only: drive the queue-head wait loop directly with an injected
    [~started_at]. Exposed so a regression test can assert that a stale
    [started_at] (e.g. one captured before a fairness cooldown) immediately
    returns [Error `Semaphore_wait_timeout] — proving the parameter is the
    timing knob whose freshness must be controlled at every call site. *)
val wait_for_autonomous_queue_head_for_test :
  keeper_name:string ->
  ticket:int ->
  started_at:float ->
  (unit, [> `Semaphore_wait_timeout of semaphore_wait_timeout ]) result

(** Pure computation: seconds keeper should yield before re-entering queue
    at time [now].  0.0 = no yield needed. *)
val fairness_delay_sec_at : now:float -> keeper_name:string -> float

(** Force-release every slot recorded for [keeper_name] in the holder
    table. Returns the [(label, age_sec)] pairs that were released so the
    caller can stamp the diagnosis. Empty list means nothing was held.

    Intended caller: the supervisor's [force_unresolved_watchdog_crash]
    path, which fires when a keeper fiber is declared crashed but did
    not return through the natural [Fun.protect] release. Without this,
    the slot is leaked until process restart (fleet starvation behind
    [reactive_turn_semaphore]).

    Side effects: [Eio.Semaphore.release] on each held semaphore plus
    [Prometheus.metric_keeper_slot_force_released]. A late-returning
    fiber may double-release; Eio counting semaphores tolerate this
    bounded over-release.

    See [keeper_turn_slot.ml] doc for full design rationale. *)
val force_release_holder_for : keeper_name:string -> (string * float) list

(** Test-only: stamp a completion time directly (bypasses [Time_compat.now]). *)
val record_autonomous_completion_at_for_test : keeper_name:string -> ts:float -> unit

(** Test-only: clear all per-keeper completion timestamps. *)
val reset_autonomous_completion_for_test : unit -> unit

(** Test-only: inject a callback immediately after an acquire flag is set
    and before the diagnostic holder row is recorded.  Used to pin that
    exception/cancel paths reclaim the semaphore even when no holder row
    exists yet. *)
val set_after_acquire_flag_hook_for_test :
  (label:string -> keeper_name:string -> unit) option -> unit

(** PR-M (Leak 9): consecutive [oas_timeout_budget] cycle FAILED strikes
    per keeper. Promoted to [Keeper_fiber_crash] at this limit.

    Counts are stored in an in-process CAS map and can be seeded from the
    persisted [Oas_timeout_budget_loop] failure reason on the first bump after
    restart or another process update. *)
val oas_timeout_budget_strike_limit : int

val bump_budget_exhaustion_seeded :
  keeper_name:string -> prior_strikes:int -> int
val bump_budget_exhaustion : keeper_name:string -> int
val reset_budget_exhaustion : keeper_name:string -> unit
val peek_budget_exhaustion_for_test : keeper_name:string -> int
val set_budget_exhaustion_for_test : keeper_name:string -> strikes:int -> unit

type keeper_turn_slot_state

val with_keeper_turn_slot :
  keeper_name:string ->
  channel:Keeper_world_observation.keeper_cycle_channel ->
  (semaphore_wait_ms:int -> 'a) ->
  ('a, [> `Semaphore_wait_timeout of semaphore_wait_timeout ]) result

(** Test-only wrapper around the keeper turn slot acquisition path. *)
val with_keeper_turn_slot_for_test :
  keeper_name:string ->
  channel:Keeper_world_observation.keeper_cycle_channel ->
  (semaphore_wait_ms:int -> 'a) ->
  ('a, [> `Semaphore_wait_timeout of semaphore_wait_timeout ]) result
