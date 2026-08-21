type agent = {
  name : string;
  status : string;
  current_task : string option;
  last_seen : string;
}

type task = {
  id : string;
  title : string;
  status : Masc_domain.task_status;
  priority : int;
}

type keeper = {
  k_name : string;
  k_generation : int;
  k_paused : bool;
  k_current_task_id : string option;
  k_total_turns : int;
  k_total_tokens : int;
  k_total_cost_usd : float;
  k_last_turn_ts : string;
  k_compaction_count : int;
  k_autonomous_turn_count : int;
  k_autonomous_text_turn_count : int;
  k_autonomous_tool_turn_count : int;
  k_board_reactive_turn_count : int;
  k_mention_reactive_turn_count : int;
  k_noop_turn_count : int;
  k_last_proactive_outcome : string;
  k_last_blocker : string option;
  k_created_at : string;
  k_updated_at : string;
}

type planning_goal = {
  pg_id : string;
  pg_title : string;
  pg_phase : Goal_phase.t;
  pg_priority : int;
  pg_due_date : string option;
  pg_metric : string option;
  pg_target_value : string option;
}

type planning_rollup = {
  pr_active : int;
  pr_paused : int;
  pr_verifying : int;
  pr_done : int;
  pr_dropped : int;
}

type planning_backlog = {
  pb_todo : int;
  pb_claimed : int;
  pb_running : int;
  pb_done : int;
  pb_cancelled : int;
}

type planning_snapshot = {
  pl_goals : planning_goal list;
  pl_rollup : planning_rollup;
  pl_backlog : planning_backlog;
  pl_generated_at : string;
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

val decode_agent : Yojson.Safe.t -> (agent, string) result
val task_of_domain : Masc_domain.task -> task
val active_tasks_of_domain : Masc_domain.task list -> task list
val decode_task : Yojson.Safe.t -> (task, string) result
val keeper_of_meta : Keeper_meta_contract.keeper_meta -> keeper
val decode_keeper : Yojson.Safe.t -> (keeper, string) result
val decode_planning_snapshot :
  Yojson.Safe.t -> (planning_snapshot, string) result
val parse_log_entry : string -> (log_entry, string) result
val is_success_http_status : int -> bool
val http_status_error : status_code:int -> body:string -> string
val decode_json_response_body :
  allow_empty:bool -> status_code:int -> body:string -> (Yojson.Safe.t, string) result
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
