(** Receipt helpers used by task scheduling. *)

val underscore_name : string -> string
val hyphen_name : string -> string
val keeper_name_from_agent_name : string -> string option
val agent_record_keeper_name : Workspace_utils.config -> agent_name:string -> string option
val keeper_receipt_candidate_names : Workspace_utils.config -> agent_name:string -> string list
val directory_exists : string -> bool
val directory_entries : string -> string list
val jsonl_files_under : string -> string list
val last_nonempty_line : string -> string option
val latest_json_in_receipt_dir : string -> Yojson.Safe.t option
val json_member_path : string list -> Yojson.Safe.t -> Yojson.Safe.t
val json_raw_string_path : string list -> Yojson.Safe.t -> string option
val json_string_path : string list -> Yojson.Safe.t -> string option
val receipt_sort_key : Yojson.Safe.t -> string

val latest_execution_receipt_json
  :  Workspace_utils.config
  -> agent_name:string
  -> Yojson.Safe.t option
