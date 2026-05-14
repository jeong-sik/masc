(** Dashboard_yjs — Yjs WebSocket Projection Layer for Live Telemetry
    @since Project World Building (Big Bang) *)

(** [frame_update payload] returns the Yjs update frame used by dashboard
    telemetry broadcasts: sync step 0, update message type 2, varint payload
    byte length, then the payload bytes. It is pure and preserves caller order
    only through the caller's own sequencing. *)
val frame_update : string -> string

(** [broadcast_keeper_telemetry ~keeper_name ~trace_id ~turn_index ~model_id]
    publishes a keeper Yjs telemetry update to dashboard observer sessions.
    [model_id] is accepted for legacy call sites but redacted to the neutral
    ["runtime"] lane in the payload. Delivery is synchronous and best-effort
    through the in-process SSE observer fanout; exceptions from disconnected
    observers are logged, while cancellation is propagated. *)
val broadcast_keeper_telemetry :
  keeper_name:string -> trace_id:string -> turn_index:int -> model_id:string -> unit

(** [broadcast_trace_telemetry ~author ~position] publishes a trace Yjs
    telemetry update to dashboard observer sessions. Ordering follows local
    caller invocation order; no cross-process ordering is guaranteed. *)
val broadcast_trace_telemetry : author:string -> position:int -> unit
