(** Telemetry helpers for keeper tool OAS handler execution. *)

(** Build the JSON payload for a keeper tool-call SSE event. *)
val keeper_tool_call_event_json
  :  keeper_name:string
  -> tool_name:string
  -> duration_ms:int
  -> disposition:('completed, 'deferred, 'failed) Tool_result.disposition
  -> ?error_text:string
  -> ?extra_fields:(string * Yojson.Safe.t) list
  -> ts:float
  -> unit
  -> Yojson.Safe.t

(** Redacted, bounded live I/O fields for keeper tool-call SSE payloads.
    SSE carries structured [tool_args]/[tool_result] plus compatibility
    previews. Secret-bearing tools omit I/O entirely and set
    [tool_io_redacted]. *)
val tool_io_preview_fields
  :  tool_name:string
  -> input:Yojson.Safe.t
  -> ?output:string
  -> unit
  -> (string * Yojson.Safe.t) list

(** Broadcast a keeper tool-call event via SSE, swallowing non-cancellation
    exceptions and logging a warning instead of crashing the turn. *)
val broadcast_keeper_tool_call_event
  :  keeper_name:string
  -> tool_name:string
  -> duration_ms:int
  -> disposition:('completed, 'deferred, 'failed) Tool_result.disposition
  -> ?error_text:string
  -> ?extra_fields:(string * Yojson.Safe.t) list
  -> site:string
  -> ts:float
  -> unit
  -> unit

(** Append a decision-log entry for a tool execution, swallowing
    non-cancellation exceptions. *)
val append_tool_exec_decision_log
  :  config:Workspace.config
  -> keeper_name:string
  -> site:string
  -> Yojson.Safe.t
  -> unit
