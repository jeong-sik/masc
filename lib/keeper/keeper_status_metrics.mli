type metrics_summary

type metrics_json_line_parse_error

type parsed_metrics_json_line = {
  metrics_line_index : int;
  metrics_json : Yojson.Safe.t;
}

type tool_audit_snapshot = {
  latest_tool_names : string list;
  latest_tool_call_count : int option;
  latest_action_source : string option;
  tool_audit_source : string option;
  tool_audit_at : string option;
}

val empty_metrics_summary : metrics_summary
val metrics_summary_to_json : metrics_summary -> Yojson.Safe.t
val parse_metrics_json_lines :
  string list -> Yojson.Safe.t list * metrics_json_line_parse_error list
val parse_metrics_json_lines_with_line_indices :
  string list -> parsed_metrics_json_line list * metrics_json_line_parse_error list
val metrics_json_line_parse_error_to_json :
  source:string ->
  ?keeper:string ->
  ?path:string ->
  metrics_json_line_parse_error ->
  Yojson.Safe.t
val summarize_metrics_lines :
  string list -> default_generation:int -> metrics_summary
val summarize_metrics_jsons :
  Yojson.Safe.t list -> default_generation:int -> metrics_summary
val empty_tool_audit_snapshot : tool_audit_snapshot
val latest_tool_audit_snapshot_from_files :
  Workspace.config -> keeper_name:string -> tool_audit_snapshot option
val accountability_summary_lookup :
  Workspace.config ->
  keeper_name:string ->
  agent_name:string ->
  Yojson.Safe.t
val accountability_summary_json :
  Workspace.config -> keeper_name:string -> agent_name:string -> Yojson.Safe.t
