(** Receipt helpers used by task scheduling. *)

val underscore_name : string -> string
val hyphen_name : string -> string
val keeper_name_from_agent_name : string -> string option

type receipt_read_error =
  | Agent_record_read_failed of { path : string; message : string }
  | Directory_stat_failed of { path : string; message : string }
  | Directory_list_failed of { path : string; message : string }
  | Receipt_line_read_failed of { path : string; message : string }
  | Receipt_json_parse_failed of { path : string; message : string }

val receipt_read_error_to_string : receipt_read_error -> string

val agent_record_keeper_name_result
  :  Workspace_utils.config
  -> agent_name:string
  -> (string option, receipt_read_error) result

val agent_record_keeper_name : Workspace_utils.config -> agent_name:string -> string option

val keeper_receipt_candidate_names_result
  :  Workspace_utils.config
  -> agent_name:string
  -> (string list, receipt_read_error) result

val keeper_receipt_candidate_names : Workspace_utils.config -> agent_name:string -> string list

val directory_exists_result : string -> (bool, receipt_read_error) result

val directory_exists : string -> bool

val directory_entries_result : string -> (string list, receipt_read_error) result

val directory_entries : string -> string list

val jsonl_files_under_result : string -> (string list, receipt_read_error) result

val jsonl_files_under : string -> string list

val last_nonempty_line_result : string -> (string option, receipt_read_error) result

val last_nonempty_line : string -> string option

val latest_json_in_receipt_dir_result
  :  string
  -> (Yojson.Safe.t option, receipt_read_error) result

val latest_json_in_receipt_dir : string -> Yojson.Safe.t option
val json_member_path : string list -> Yojson.Safe.t -> Yojson.Safe.t
val json_raw_string_path : string list -> Yojson.Safe.t -> string option
val json_string_path : string list -> Yojson.Safe.t -> string option
val receipt_sort_key : Yojson.Safe.t -> string

val latest_execution_receipt_json_result
  :  Workspace_utils.config
  -> agent_name:string
  -> (Yojson.Safe.t option, receipt_read_error) result

val latest_execution_receipt_json
  :  Workspace_utils.config
  -> agent_name:string
  -> Yojson.Safe.t option
