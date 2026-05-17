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

val handoff_requested
  :  ts_unix:float
  -> correlation_id:string
  -> run_id:string
  -> from_agent:string
  -> to_agent:string
  -> reason:string
  -> Yojson.Safe.t

val handoff_completed
  :  ts_unix:float
  -> correlation_id:string
  -> run_id:string
  -> from_agent:string
  -> to_agent:string
  -> elapsed_s:float
  -> Yojson.Safe.t

val context_compacted
  :  ts_unix:float
  -> correlation_id:string
  -> run_id:string
  -> agent_name:string
  -> before_tokens:int
  -> after_tokens:int
  -> phase:string
  -> Yojson.Safe.t

val context_overflow_imminent
  :  ts_unix:float
  -> correlation_id:string
  -> run_id:string
  -> agent_name:string
  -> estimated_tokens:int
  -> limit_tokens:int
  -> ratio:float
  -> Yojson.Safe.t

val context_compact_started
  :  ts_unix:float
  -> correlation_id:string
  -> run_id:string
  -> agent_name:string
  -> trigger:string
  -> Yojson.Safe.t

val content_replacement_replaced
  :  ts_unix:float
  -> correlation_id:string
  -> run_id:string
  -> tool_use_id:string
  -> preview:string
  -> original_chars:int
  -> seen_count_after:int
  -> Yojson.Safe.t

val content_replacement_kept
  :  ts_unix:float
  -> correlation_id:string
  -> run_id:string
  -> tool_use_id:string
  -> seen_count_after:int
  -> Yojson.Safe.t

val slot_scheduler_observed
  :  ts_unix:float
  -> correlation_id:string
  -> run_id:string
  -> max_slots:int
  -> active:int
  -> available:int
  -> queue_length:int
  -> state:string
  -> Yojson.Safe.t
