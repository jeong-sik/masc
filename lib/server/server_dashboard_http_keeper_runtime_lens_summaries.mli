(** Runtime-lens support summaries for keeper runtime trace responses. *)

val claim_scope_summary_json :
  keeper_name:string ->
  trace_id:string ->
  ?turn_id:int ->
  unit ->
  Yojson.Safe.t

val claim_scope_summary_of_tool_call_json : Yojson.Safe.t -> Yojson.Safe.t
(** Pure projection for a matching [keeper_task_claim] tool-call row. Malformed
    tool output becomes [status=read_error] rather than an empty claim scope. *)

val config_drift_summary_json :
  config:Workspace.config -> keeper_name:string -> Yojson.Safe.t
