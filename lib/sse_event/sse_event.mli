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
