open Keeper_types

(** Inject the shared Event_bus for keeper snapshot publishing. *)
val set_bus : Agent_sdk.Event_bus.t -> unit

(** Retrieve the shared Event_bus, if set. *)
val get_bus : unit -> Agent_sdk.Event_bus.t option

(** Inject a gRPC client for heartbeat streaming.
    When set and [MASC_AGENT_TRANSPORT=grpc], keepalive will also
    send heartbeat pings over the gRPC bidirectional stream. *)
val set_grpc_client : Masc_grpc_client.t -> unit

(** Wake up a specific keeper immediately. Used by broadcast notification
    when a @mention targets a running keeper. *)
val wakeup_keeper : string -> unit

(** Wake up all running keepers. Used for @@all broadcast mentions
    or system-wide events. *)
val wakeup_all_keepers : unit -> unit

val wakeup_relevant_keeper_for_board_signal :
  config:Room.config -> Board_dispatch.keeper_board_signal -> unit

(** The heartbeat loop body, extracted for reuse by the supervisor.
    Runs synchronously in the calling fiber until [stop] becomes true. *)
val run_heartbeat_loop :
  proactive_warmup_sec:int -> 'a context -> keeper_meta -> bool ref ->
  wakeup:bool ref -> unit

val start_keepalive :
  ?proactive_warmup_sec:int -> 'a context -> keeper_meta -> unit
val stop_keepalive : string -> unit
