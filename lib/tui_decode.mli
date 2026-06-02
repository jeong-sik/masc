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
  k_goal : string;
  k_short_goal : string;
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
  le_goal_alignment : float option;
  le_repetition_risk : float option;
  le_guardrail_stop : bool option;
}

val decode_agent : Yojson.Safe.t -> (agent, string) result
val decode_task : Yojson.Safe.t -> (task, string) result
val decode_keeper : filename:string -> Yojson.Safe.t -> (keeper, string) result
val parse_log_entry : string -> (log_entry, string) result
val parse_keeper_chat_response : string -> (string, string) result
