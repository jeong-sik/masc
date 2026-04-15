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
    when a @mention targets a running keeper. *)
val wakeup_keeper : ?base_path:string -> string -> unit

(** Wake up all running keepers. Used for @@all broadcast mentions
    or system-wide events. *)
val wakeup_all_keepers : ?base_path:string -> unit -> unit

val keeper_turn_throttle_limit : int
(** Runtime keeper turn concurrency limit derived from
    [MASC_KEEPER_AUTOBOOT_MAX]. *)

val semaphore_wait_timeout_sec : float
(** Wall-clock cap on [Eio.Semaphore.acquire] when waiting for a keeper
    turn slot. Derived from [MASC_KEEPER_SEMAPHORE_WAIT_TIMEOUT_SEC]
    (default 60.0, range [5, 600]). Keepers whose peers hold slots past
    this cap are skipped for the current cycle and retry on the next
    heartbeat. *)

exception Semaphore_wait_timeout of float
(** Raised inside [with_keeper_turn_slot] when acquiring either the
    autonomous or turn semaphore exceeds [semaphore_wait_timeout_sec].
    The float carries the wait cap so the caller can render it without
    re-reading the env var. Callers should treat this as "skip this
    turn, retry on next heartbeat" rather than a keeper failure. *)

(** Test-only reset for the autonomous FIFO wait queue. *)
val reset_autonomous_turn_queue_for_test : unit -> unit

(** Test-only snapshot of keeper names currently queued for an autonomous turn. *)
val autonomous_waiter_snapshot_for_test : unit -> string list

(** Test-only FIFO queue primitives for autonomous fairness regression tests. *)
val enqueue_autonomous_waiter_for_test : string -> int
val drop_autonomous_waiter_for_test : int -> unit

(** Pure computation: seconds keeper should yield before re-entering queue
    at time [now].  0.0 = no yield needed.  Exposed for unit testing. *)
val fairness_delay_sec_at : now:float -> keeper_name:string -> float

(** Test-only: stamp a completion time directly (bypasses [Time_compat.now]).
    Use to set up deterministic fairness-cooldown scenarios. *)
val record_autonomous_completion_at_for_test : keeper_name:string -> ts:float -> unit

(** Test-only: clear all per-keeper completion timestamps. *)
val reset_autonomous_completion_for_test : unit -> unit

val wakeup_relevant_keeper_for_board_signal :
  config:Room.config -> Board_dispatch.keeper_board_signal -> unit

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
