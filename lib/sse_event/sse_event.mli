(** RFC-0004 Phase A0.1 PR-1 — typed SSE event wrapper public interface. *)

type envelope_meta =
  { event_type : string
  ; ts_unix : float
  ; correlation_id : string
  ; run_id : string
  ; agent_name : string option
  ; task_id : string option
  ; turn : int option
  ; tool_name : string option
  }

val json_string_opt : string option -> Yojson.Safe.t
val wrap_envelope : envelope_meta -> Yojson.Safe.t -> Yojson.Safe.t

val agent_started
  :  ts_unix:float
  -> correlation_id:string
  -> run_id:string
  -> agent_name:string
  -> task_id:string
  -> Yojson.Safe.t

val tool_called
  :  ts_unix:float
  -> correlation_id:string
  -> run_id:string
  -> agent_name:string
  -> tool_name:string
  -> Yojson.Safe.t

val tool_completed
  :  ts_unix:float
  -> correlation_id:string
  -> run_id:string
  -> agent_name:string
  -> tool_name:string
  -> Yojson.Safe.t

val turn_started
  :  ts_unix:float
  -> correlation_id:string
  -> run_id:string
  -> agent_name:string
  -> turn:int
  -> Yojson.Safe.t

val turn_completed
  :  ts_unix:float
  -> correlation_id:string
  -> run_id:string
  -> agent_name:string
  -> turn:int
  -> Yojson.Safe.t

val turn_ready
  :  ts_unix:float
  -> correlation_id:string
  -> run_id:string
  -> agent_name:string
  -> turn:int
  -> tool_names:string list
  -> Yojson.Safe.t
