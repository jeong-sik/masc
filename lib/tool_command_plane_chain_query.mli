(** Tool_command_plane_chain_query -- chain snapshot, run retrieval,
    operation/intent/checkpoint, topology, alerts, swarm, and trace
    observation handlers for the command-plane tool surface.

    Only {!backfill_chain_overlays} is called externally by name;
    the [handle_*] functions are dispatched via tool routing. *)

open Tool_command_plane_support

(** {1 Chain overlay backfill} *)

(** Backfill chain history, mermaid, and preview_run overlays
    for all operations that have a linked chain. *)
val backfill_chain_overlays : Room.config -> unit

(** {1 Chain summary and run} *)

val handle_chain_snapshot : ('a, 'b) context -> result
val handle_chain_run_get  : ('a, 'b) context -> Yojson.Safe.t -> result

(** {1 Operation and intent} *)

val handle_operation_status     : ('a, 'b) context -> Yojson.Safe.t -> result
val handle_intent_create        : ('a, 'b) context -> Yojson.Safe.t -> result
val handle_intent_status        : ('a, 'b) context -> Yojson.Safe.t -> result
val handle_intent_update        : ('a, 'b) context -> Yojson.Safe.t -> result
val handle_intent_forecast      : ('a, 'b) context -> Yojson.Safe.t -> result
val handle_operation_checkpoint : ('a, 'b) context -> Yojson.Safe.t -> result

(** {1 Observation} *)

val handle_observe_topology   : ('a, 'b) context -> result
val handle_observe_alerts     : ('a, 'b) context -> result
val handle_observe_operations : ('a, 'b) context -> result
val handle_observe_swarm      : ('a, 'b) context -> Yojson.Safe.t -> result
val handle_observe_capacity   : ('a, 'b) context -> result
val handle_observe_traces     : ('a, 'b) context -> Yojson.Safe.t -> result
