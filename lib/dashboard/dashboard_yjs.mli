(** Dashboard_yjs — Yjs WebSocket Projection Layer for Live Telemetry
    @since Project World Building (Big Bang) *)

val frame_update : string -> string
(** [frame_update payload] wraps [payload] in the Yjs sync frame envelope
    used by browser-side Y.applyUpdate consumers: two leading control
    bytes [\x00\x02] followed by the payload length encoded as a Yjs
    varint, followed by the payload itself.  Pure function — the byte
    layout is the wire contract pinned by [test_dashboard_yjs]. *)

(** [broadcast_keeper_telemetry ~keeper_name ~trace_id ~turn_index]
    publishes a keeper Yjs telemetry update to dashboard observer sessions.
    Delivery is synchronous and best-effort through the in-process SSE observer
    fanout; exceptions from disconnected observers are logged, while cancellation
    is propagated. *)
val frame_update : string -> string
(** Encode a payload into the Yjs binary sync-protocol frame format. *)

val broadcast_keeper_telemetry :
  keeper_name:string -> trace_id:string -> turn_index:int -> unit
