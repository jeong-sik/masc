type metrics_summary

type tool_audit_snapshot = {
  latest_tool_names : string list;
  latest_tool_call_count : int option;
  tool_audit_source : string option;
  tool_audit_at : string option;
}

val empty_metrics_summary : metrics_summary
val metrics_summary_to_json : metrics_summary -> Yojson.Safe.t
val summarize_metrics_lines :
  string list -> default_generation:int -> metrics_summary
val empty_tool_audit_snapshot : tool_audit_snapshot
val latest_tool_audit_snapshot_from_files :
  Room.config -> keeper_name:string -> tool_audit_snapshot option
