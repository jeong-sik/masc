(** Dashboard_yjs — Yjs WebSocket Projection Layer for Live Telemetry
    @since Project World Building (Big Bang) *)

(** [frame_update payload] returns the Yjs update frame used by dashboard
    telemetry broadcasts: sync step 0, update message type 2, varint
    payload byte length, then the payload bytes. Pure; preserves caller
    order only through the caller's own sequencing.

    Exposed for unit tests so the binary protocol encoding stays pinned
    at the test boundary — a silent change to the varint or message
    type would surface in dashboard observer parsers as malformed
    frames, which is harder to diagnose than a unit-test failure. The
    live entry point [broadcast_keeper_telemetry] consumes this
    internally. *)
val frame_update : string -> string

(** [broadcast_keeper_telemetry ~keeper_name ~trace_id ~turn_index ~model_id]
    publishes a keeper Yjs telemetry update to dashboard observer sessions.
    [model_id] is accepted for legacy call sites but redacted to the neutral
    ["runtime"] lane in the payload. Delivery is synchronous and best-effort
    through the in-process SSE observer fanout; exceptions from disconnected
    observers are logged, while cancellation is propagated. *)
val broadcast_keeper_telemetry :
  keeper_name:string -> trace_id:string -> turn_index:int -> model_id:string -> unit

