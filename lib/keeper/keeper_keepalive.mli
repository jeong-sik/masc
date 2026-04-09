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
val wakeup_keeper : string -> unit

(** Wake up all running keepers. Used for @@all broadcast mentions
    or system-wide events. *)
val wakeup_all_keepers : unit -> unit

val keeper_turn_throttle_limit : int
(** Runtime keeper turn concurrency limit derived from
    [MASC_KEEPER_AUTOBOOT_MAX]. *)

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
