(** Dashboard_yjs — Yjs WebSocket Projection Layer for Live Telemetry
    @since Project World Building (Big Bang) *)

(** Start the Yjs WebSocket syncing server to stream 64+ keeper state diffs. *)
val start_server : port:int -> unit

(** Broadcast a state update into the CRDT document. *)
val broadcast_update : string -> unit
