(** Incremental telemetry summary for fleet health.

    Maintains an in-memory incremental aggregation of telemetry events
    received from the OAS event bus.  Avoids O(N) re-scan of durable
    telemetry data on every query — counters are updated as events arrive.
    This prevents the fleet freeze that occurred when the FSM audit
    append performed a blocking full-scan of the event timeline.

    Design: incremental counter aggregation behind a short critical
    section plus a small ring buffer of recent events, so reads avoid
    durable-history scans. *)

(** Type of a single recorded telemetry event summary entry. *)
type telemetry_entry = {
  timestamp : float;
  keeper_name : string;
  event_kind : string;
  runtime_id : string option;
  duration_ms : float option;
  success : bool;
}

(** Snapshot of fleet telemetry counters. *)
type fleet_snapshot = {
  total_events : int;
  successful_events : int;
  failed_events : int;
  per_keeper : (string, keeper_counters) Hashtbl.t;
  recent_events : telemetry_entry list;
}

and keeper_counters = {
  total : int;
  success : int;
  failure : int;
  avg_duration_ms : float;
}

(** Register a new telemetry event for incremental aggregation.
    Must be called from the telemetry consumer drain fiber or
    equivalent event-receiving context.  Non-blocking. *)
val record_event
  :  keeper_name:string
  -> event_kind:string
  -> runtime_id:string option
  -> duration_ms:float option
  -> success:bool
  -> unit

(** Decode and record a [Custom("telemetry_event", payload)] event-bus
    payload. Missing optional fields are treated conservatively: unknown
    keeper/runtime labels are bounded, and observed telemetry events default
    to success unless an explicit failure/error status is present. *)
val record_telemetry_payload : Yojson.Safe.t -> unit

(** Return a point-in-time snapshot of all aggregated counters.
    Non-blocking — reads atomics and a locked ring buffer. *)
val snapshot : unit -> fleet_snapshot

(** Reset all aggregated counters.  Useful for testing or
    after a window boundary. *)
val reset : unit -> unit

(** Reset per-keeper counters only; keeps the global counter
    and recent event buffer unchanged. *)
val reset_keeper : keeper_name:string -> unit
