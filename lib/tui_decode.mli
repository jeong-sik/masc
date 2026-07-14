type agent = {
  name : string;
  status : string;
  current_task : string option;
  last_seen : string;
}

type task = {
  id : string;
  title : string;
  status : string;
  priority : int;
  claimed_by : string option;
  parent_task_id : string option;
  goal_id : string option;
}

type keeper = {
  k_name : string;
  k_active_goal_ids : string list;
  k_generation : int;
  k_active_model : string option;
  k_models : string list;
  k_proactive_enabled : bool;
  k_initiative_enabled : bool option;
  k_total_turns : int;
  k_total_tokens : int;
  k_total_cost_usd : float;
  k_last_turn_ts : string;
  k_compaction_count : int;
  k_compaction_ratio_gate : float;
  k_trigger_mode : string;
  k_context_budget : int;
  k_handoff_threshold : float;
  k_drift_enabled : bool;
  k_verify : bool;
  k_created_at : string;
  k_updated_at : string;
}

type log_entry = {
  le_ts : string;
  le_channel : string;
  le_context_ratio : float;
  le_context_tokens : int;
  le_context_max : int;
  le_message_count : int;
  le_model_used : string option;
  le_input_tokens : int option;
  le_output_tokens : int option;
  le_latency_ms : int option;
  le_cost_usd : float option;
  le_work_kind : string option;
  le_tools_used : string list;
  le_compacted : bool option;
}

type http_response = {
  status_code : int;
  body : string;
}

val decode_agent : Yojson.Safe.t -> (agent, string) result
val decode_task : Yojson.Safe.t -> (task, string) result
val decode_keeper : filename:string -> Yojson.Safe.t -> (keeper, string) result
val parse_log_entry : string -> (log_entry, string) result
val parse_http_response : string -> (http_response, string) result
val is_success_http_status : int -> bool
val http_status_error : http_response -> string
val decode_json_response_body :
  allow_empty:bool -> status_code:int -> body:string -> (Yojson.Safe.t, string) result
val decode_json_http_response :
  allow_empty:bool -> string -> (Yojson.Safe.t, string) result
val required_string_field : Yojson.Safe.t -> string -> (string, string) result
val optional_string_field :
  Yojson.Safe.t -> string -> (string option, string) result
val required_int_field : Yojson.Safe.t -> string -> (int, string) result
val required_int_any_field : Yojson.Safe.t -> string list -> (int, string) result
val int_field_or : Yojson.Safe.t -> string -> default:int -> (int, string) result
val required_display_field : Yojson.Safe.t -> string -> (string, string) result
val required_display_any_field :
  Yojson.Safe.t -> string list -> (string, string) result
val optional_body_field : Yojson.Safe.t -> (string, string) result
val required_body_field : Yojson.Safe.t -> (string, string) result
val required_list_field :
  Yojson.Safe.t -> string -> (Yojson.Safe.t list, string) result
val optional_list_field :
  Yojson.Safe.t -> string -> (Yojson.Safe.t list, string) result
val required_object_field :
  Yojson.Safe.t -> string -> (Yojson.Safe.t, string) result
val optional_object_field :
  Yojson.Safe.t -> string -> (Yojson.Safe.t option, string) result
val decode_list :
  string -> (Yojson.Safe.t -> ('a, string) result) -> Yojson.Safe.t list -> ('a list, string) result
val bounded_parent_depth :
  ?max_depth:int ->
  id_of:('a -> string) ->
  parent_id_of:('a -> string option) ->
  'a list ->
  'a ->
  int
val parse_keeper_chat_response : string -> (string, string) result
