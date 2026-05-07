(** Stale-turn watchdog — standalone fiber for keeper liveness detection.

    @since PR #10670 — extracted from Keeper_supervisor. *)

open Keeper_types

val slot_holder_age_for_test :
  now:float -> keeper_name:string -> float option
(** Test-only view of the watchdog's fallback in-flight signal.  Returns
    the oldest slot-holder age for [keeper_name] across turn, reactive,
    and autonomous holder tables. *)

type batch_root_cause =
  | Cascade_unhealthy
  | Provider_auth
  | Fd_exhaustion
  | Mixed
  | Unknown
(** Low-cardinality root-cause label for fleet-wide stale termination
    batches.  This is derived from already-latched keeper failure
    reasons, so dashboards get a typed signal instead of parsing the
    batch log line. *)

val batch_root_cause_to_string : batch_root_cause -> string

val classify_batch_root_cause_for_test :
  Keeper_registry.failure_reason list -> batch_root_cause
(** Test-only view of the batch root-cause classifier. *)

val reset_batch_terminations_for_test : unit -> unit
(** Test-only reset for fleet batch termination history. *)

val record_batch_termination_for_test : string -> float -> string list
(** Test-only wrapper around the fleet batch termination window. *)

val latch_stale_fleet_batch_reasons_for_test :
  config:Coord.config -> distinct_count:int -> string list -> unit
(** Test-only wrapper for the batch failure-reason latch. *)

type stale_watchdog_action =
  | No_action
  | Request_idle_recovery of { stall_seconds : float }
  | Terminate of Keeper_registry.stale_kill_class
(** Action chosen after the watchdog has classified the current liveness
    snapshot. Idle stalls are wake-first; watchdog termination is reserved
    for active-turn hangs, no-op failure loops, and idle stalls that ignore
    a prior watchdog wake for the active-turn timeout budget. *)

val classify_stale_watchdog_action_for_test :
  now:float ->
  threshold:float ->
  active_turn_timeout_sec:float ->
  last_turn:float ->
  idle_stale:bool ->
  in_turn_stale:bool ->
  in_turn_age:float ->
  failure_loop:bool ->
  noop_count:int ->
  last_idle_wakeup_ts:float ->
  stale_watchdog_action
(** Test-only view of the watchdog action selector. *)

val current_generation_noop_failure_loop_for_test :
  noop_count:int -> noop_threshold:int -> last_turn:float -> started_at:float -> bool
(** Test-only view of the no-op loop guard. Persisted no-op counts are
    only watchdog-fatal after this fiber generation has completed a turn. *)

val fork_stale_watchdog :
  'a context -> keeper_meta -> Keeper_registry.registry_entry -> unit
(** Fork a stale-turn watchdog fiber for the given keeper.

    Three detection modes — see {!Keeper_registry.stale_kill_class}:
    - [Idle_turn]: [last_turn_ts] older than the idle threshold while
      the keeper phase is [Running] but no [current_turn_observation]
      is recorded. This class now terminates only after a wake-first idle
      recovery stimulus has also been ignored for the active-turn timeout
      budget.
    - [In_turn_hung]: a turn started ([current_turn_observation = Some])
      and ran past [timeout_threshold] seconds — covers the
      "Orphaned Streaming" pattern described in the executor FSM
      analysis (TLA+ I2: [in_turn_age > grace_period → in_turn_stale]).
    - [Noop_failure_loop]: turns kept firing but produced no tool
      calls; the keepalive's [consecutive_noop_count] reached the
      watchdog threshold — catches keepers in LLM timeout loops where
      [last_turn_ts] stays fresh because each failed turn updates it.

    Detection class is exposed on the
    [masc_keeper_stale_termination_by_class] Prometheus counter for
    per-class root-cause attribution.

    Idle stalls first enqueue a recovery stimulus and wake the heartbeat
    fiber. Termination is reserved for [In_turn_hung],
    [Noop_failure_loop], unresolved OAS timeout budget loops, or an idle
    stall that ignores a prior watchdog wake for the active-turn timeout
    budget. On termination, sets [fiber_stop] and emits a stale broadcast.
    The supervisor's [sweep_and_recover] picks up the stopped fiber and
    restarts with exponential backoff, unless a per-keeper stale storm or
    fleet batch latch routes the keeper to auto-pause/backoff first. *)
