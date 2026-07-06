(** Keeper tool execution marker extraction. *)

val sse_error_preview_max_chars : int
(** Max chars for the SSE error preview rendered to dashboards. *)

type output_marker_parse_error =
  | Output_marker_json_decode_error of string

type tool_exec_result_marker_report =
  { markers : string list
  ; output_parse_error : output_marker_parse_error option
  }

val output_marker_parse_error_to_string :
  output_marker_parse_error -> string

val tool_exec_result_marker_report :
  input:Yojson.Safe.t -> output:string -> tool_exec_result_marker_report
(** Extract safe decision-log markers and report output JSON parse
    failures separately.  A malformed output payload does not invalidate
    input-derived markers or the tool result itself. *)

val tool_exec_result_markers :
  input:Yojson.Safe.t -> output:string -> string list
(** Compatibility projection over {!tool_exec_result_marker_report}. *)
