(** Telemetry helpers for keeper tool OAS handler execution. *)

(** Build the JSON payload for a keeper tool-call SSE event. *)
val keeper_tool_call_event_json
  :  keeper_name:string
  -> tool_name:string
  -> duration_ms:int
  -> success:bool
  -> ?error_text:string
  -> ?extra_fields:(string * Yojson.Safe.t) list
  -> ts:float
  -> unit
  -> Yojson.Safe.t

(** Broadcast a keeper tool-call event via SSE, swallowing non-cancellation
    exceptions and logging a warning instead of crashing the turn. *)
val broadcast_keeper_tool_call_event
  :  keeper_name:string
  -> tool_name:string
  -> duration_ms:int
  -> success:bool
  -> ?error_text:string
  -> ?extra_fields:(string * Yojson.Safe.t) list
  -> site:string
  -> ts:float
  -> unit
  -> unit

(** Append a decision-log entry for a tool execution, swallowing
    non-cancellation exceptions. *)
val append_tool_exec_decision_log
  :  config:Coord.config
  -> keeper_name:string
  -> site:string
  -> Yojson.Safe.t
  -> unit
