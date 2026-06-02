(** Keeper tool execution marker extraction. *)

val sse_error_preview_max_chars : int
(** Max chars for the SSE error preview rendered to dashboards. *)

val tool_exec_result_markers :
  input:Yojson.Safe.t -> output:string -> string list
(** Extract safe decision-log markers from tool input/output envelopes. *)
