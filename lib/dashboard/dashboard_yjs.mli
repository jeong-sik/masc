(** Dashboard_yjs — Yjs WebSocket Projection Layer for Live Telemetry
    @since Project World Building (Big Bang) *)

val broadcast_keeper_telemetry : keeper_name:string -> trace_id:string -> turn_index:int -> model_id:string -> unit
val broadcast_trace_telemetry : author:string -> position:int -> unit
