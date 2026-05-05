open Keeper_types

(** Inject the shared Event_bus for keeper snapshot publishing. *)
val set_bus : Agent_sdk.Event_bus.t -> unit

(** Retrieve the shared Event_bus, if set. *)
val get_bus : unit -> Agent_sdk.Event_bus.t option

(** Inject a gRPC client for bidirectional heartbeat streaming.
    When set and [MASC_AGENT_TRANSPORT=grpc], keepalive opens a
    persistent bidi [Heartbeat] stream, sends [HeartbeatPing] at
    each interval, and processes [HeartbeatAck] directives. *)
val set_grpc_client : ?env:Eio_unix.Stdenv.base -> Masc_grpc_client.t -> unit

(** Process a single directive string from a gRPC HeartbeatAck.
    Supported: "pause", "resume", "wakeup", "claim:<task_id>". *)
val process_directive : agent_name:string -> string -> unit

(** Wake up a specific keeper immediately. Used by broadcast notification
    when a @mention targets a running keeper.

    [?stimulus] appends the payload to the keeper's Event Layer queue
    before flipping the wakeup flag. See RFC-0020 §3. *)
val wakeup_keeper :
  ?base_path:string ->
  ?stimulus:Keeper_event_queue.stimulus ->
  string -> unit

(** Wake up all running keepers. Used for @@all broadcast mentions
    or system-wide events. *)
val wakeup_all_keepers : ?base_path:string -> unit -> unit

val keeper_turn_throttle_limit : int
(** Runtime keeper turn concurrency limit derived from
    [MASC_KEEPER_AUTOBOOT_MAX]. *)

val proactive_skip_reason_metric : string
(** Canonical Prometheus metric name for the proactive-scheduler
    skip-reason counter.  Labels: [("keeper", <name>); ("reason",
    <skip_reason_label>)].  [reason] is produced by
    [Keeper_world_observation.verdict_reasons_to_strings] and is
    one of [keeper_paused | approval_pending |
    scheduled_autonomous_disabled | provider_cooldown_pending |
    idle_gate_pending | cooldown_pending | no_signal].
    #10008 failure mode 3. *)

val semaphore_wait_timeout_sec : float
(** Wall-clock cap on [Eio.Semaphore.acquire] when waiting for a keeper
    turn slot. Derived from [MASC_KEEPER_SEMAPHORE_WAIT_TIMEOUT_SEC]
    (default 60.0, range [5, 600]). Keepers whose peers hold slots past
    this cap are skipped for the current cycle and retry on the next
    heartbeat. *)

exception Semaphore_wait_timeout of float
(** Raised inside [with_keeper_turn_slot] when acquiring either the
    autonomous, reactive, or global turn semaphore exceeds
    [semaphore_wait_timeout_sec]. The float carries the wait cap so the
    caller can render it without re-reading the env var. Callers should
    treat this as "skip this turn, retry on next heartbeat" rather than
    a keeper failure. *)

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
    Sorted by descending hold time. *)
val turn_slot_holders : now:float -> (string * float) list
val autonomous_slot_holders : now:float -> (string * float) list
val reactive_slot_holders : now:float -> (string * float) list

(** Test-only FIFO queue primitives for autonomous fairness regression tests. *)
val enqueue_autonomous_waiter_for_test : string -> int
val drop_autonomous_waiter_for_test : int -> unit

(** Pure computation: seconds keeper should yield before re-entering queue
    at time [now].  0.0 = no yield needed.  Exposed for unit testing. *)
val fairness_delay_sec_at : now:float -> keeper_name:string -> float

(** Pure: whether a [Heartbeat_smart] decision should allow the
    keepalive cycle (presence/snapshot/board/turn/recurring) to run.

    Contract: [Skip_busy] -> [true] (cycle continues; broadcast may be
    debounced elsewhere). [Skip_idle] -> [false] (keeper idle, back
    off). [Emit] -> [true]. Regression guard for the claim-holding
    keeper starvation bug where [Skip_busy] was mis-used as a
    cycle-skip signal, blocking any keeper with a claimed task from
    ever running a turn. *)
val smart_heartbeat_cycle_continues : Heartbeat_smart.decision -> bool

(** Pure: post-sleep refinement. Promotes [Skip_idle] to [true] iff the
    sleep ended with [Woken]. Closes the [MissedWakeup] gap in
    KeeperHeartbeat.tla left open by sibling fix #10078. *)
val cycle_continues_after_wake :
  Heartbeat_smart.decision -> Keeper_keepalive_signal.sleep_outcome -> bool

val status_tick_usage_json : unit -> Yojson.Safe.t
(** Usage payload for heartbeat/status metrics rows.  Status ticks are not
    LLM calls, so all per-turn token counters are explicit zeroes while
    preserving the same cache-token field shape as turn snapshots. *)

(** Test-only: stamp a completion time directly (bypasses [Time_compat.now]).
    Use to set up deterministic fairness-cooldown scenarios. *)
val record_autonomous_completion_at_for_test : keeper_name:string -> ts:float -> unit

(** Test-only: clear all per-keeper completion timestamps. *)
val reset_autonomous_completion_for_test : unit -> unit

(** PR-M (Leak 9): consecutive [oas_timeout_budget] cycle FAILED strikes
    per keeper. Promoted to [Keeper_fiber_crash] at
    [oas_timeout_budget_strike_limit]; reset on any successful turn.
    Counter survives within a server lifetime — restart resets it,
    which is the desired behavior since the new fiber starts with
    a fresh budget context. *)
val oas_timeout_budget_strike_limit : int

val bump_budget_exhaustion : keeper_name:string -> int
(** Increment the strike count for [keeper_name] and return the new
    count.  Thread-safe under [Eio.Mutex]. *)

val reset_budget_exhaustion : keeper_name:string -> unit
(** Drop any strike count for [keeper_name].  Idempotent. *)

val peek_budget_exhaustion_for_test : keeper_name:string -> int
(** Test-only: read current strike count without mutating. *)

val set_budget_exhaustion_for_test :
  keeper_name:string -> strikes:int -> unit
(** Test-only: pre-load strike count.  [strikes <= 0] is equivalent
    to [reset_budget_exhaustion]. *)

(** Test-only wrapper around the keeper turn slot acquisition path. *)
val with_keeper_turn_slot_for_test :
  keeper_name:string ->
  channel:Keeper_world_observation.keeper_cycle_channel ->
  (semaphore_wait_ms:int -> 'a) ->
  ('a, [> `Semaphore_wait_timeout of float ]) result

(** Test-only wrapper for the in-turn liveness pulse lifecycle. *)
val with_in_turn_liveness_pulse_for_test :
  sw:Eio.Switch.t ->
  clock:'a Eio.Time.clock ->
  interval_sec:float ->
  tick:(unit -> unit) ->
  (unit -> 'b) ->
  'b

(** Keepalive loop meta selection. Disk wins when it changed; otherwise
    fall back to the latest registry snapshot instead of the original boot
    meta so continuity/runtime fields do not regress across turns. *)
val effective_keepalive_meta :
  base_path:string ->
  fallback:keeper_meta ->
  disk_meta_opt:keeper_meta option ->
  keeper_meta

val wakeup_relevant_keeper_for_board_signal :
  config:Coord.config -> Board_dispatch.keeper_board_signal -> unit

(** The heartbeat loop body, extracted for reuse by the supervisor.
    Runs synchronously in the calling fiber until [stop] becomes true. *)
val run_heartbeat_loop :
  proactive_warmup_sec:int -> 'a context -> keeper_meta -> bool Atomic.t ->
  wakeup:bool Atomic.t -> unit

(** Compute the p-th percentile of a float array.
    Returns 0.0 for empty arrays. Used by per-stage profiling. *)
val percentile : float array -> float -> float

val start_keepalive :
  ?proactive_warmup_sec:int -> 'a context -> keeper_meta -> unit
val stop_keepalive : ?base_path:string -> string -> unit
val stop_all_keepalives : unit -> unit
