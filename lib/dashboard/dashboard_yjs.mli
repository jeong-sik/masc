(** Dashboard_yjs — Yjs WebSocket Projection Layer for Live Telemetry
    @since Project World Building (Big Bang) *)

val frame_update : string -> string
(** [frame_update payload] wraps [payload] in the binary Yjs
    update-message envelope: a 2-byte type header followed by a
    varint-encoded length prefix and the raw payload bytes. Exposed
    for [test_dashboard_yjs], which round-trips the frame encoding
    independently of the broadcast pipeline. *)

(** [broadcast_keeper_telemetry ~keeper_name ~trace_id ~turn_index ~model_id]
    publishes a keeper Yjs telemetry update to dashboard observer sessions.
    [model_id] is accepted for legacy call sites but redacted to the neutral
    ["runtime"] lane in the payload. Delivery is synchronous and best-effort
    through the in-process SSE observer fanout; exceptions from disconnected
    observers are logged, while cancellation is propagated. *)
val broadcast_keeper_telemetry :
  keeper_name:string -> trace_id:string -> turn_index:int -> model_id:string -> unit

