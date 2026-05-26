val default_cascade_name : unit -> string
val phase_recovery_cascade_name : string
val phase_buffer_cascade_name : string
val phase_routing_cascade_names : string list
val tool_required_cascade_name : string
val min_keeper_context_tokens : int
val max_keeper_context_tokens : int
val alert_error_detail_max_chars : int
val alert_excerpt_min_chars : int
val alert_message_preview_max_chars : int
val alert_reply_preview_max_chars : int
val tool_policy_count_warn_threshold : int
val tool_first_sentence_max_chars : int
val default_proactive_enabled : bool
val default_proactive_idle_sec : int
val default_proactive_cooldown_sec : int
val approval_queue_stale_max_wait_sec : float
val default_room_signal_prompt_enabled : bool
val default_goal_horizon_max_chars : int
val default_drift_max_clauses : int
val legacy_provider_filter_name : string
val prompt_render_max_bytes : int
val bool_default_true_of_env : string -> bool
val bool_of_env_default : string -> default:bool -> bool
val bool_of_env_opt : string -> bool option
val bool_of_string : string -> bool option
val int_of_env_default :
  string -> default:int -> min_v:int -> max_v:int -> int
val float_of_env_default :
  string -> default:float -> min_v:float -> max_v:float -> float
val clamp_int : int -> min_v:int -> max_v:int -> int
val validate_name : string -> bool
val removed_keeper_input_key_names : string list
val removed_keeper_msg_input_key_names : string list
val removed_keeper_meta_key_names : string list
val present_json_keys : string list -> Yojson.Safe.t -> string list
val reject_removed_keeper_input_keys :
  tool_name:string -> Yojson.Safe.t -> (unit, string) result
val reject_removed_keeper_msg_input_keys :
  tool_name:string -> Yojson.Safe.t -> (unit, string) result
val utf8_safe_prefix_bytes : string -> max_bytes:int -> string
val utf8_repair_string : string -> string
val normalize_self_model_text : max_bytes:int -> string -> string
val normalize_goal_horizon_text : ?max_len:int -> string -> string
val normalize_goal_horizon_opt : string option -> string option
val parse_goal_horizon_opt : Yojson.Safe.t -> string -> string option
val resolve_goal_horizons :
  goal:string ->
  short_goal_opt:string option ->
  mid_goal_opt:string option ->
  long_goal_opt:string option -> string * string * string
val split_semicolon_clauses : string -> string list
val take_last : int -> 'a list -> 'a list
val compact_self_model_text :
  ?max_clauses:int -> max_bytes:int -> string -> string
val parse_self_model_opt : Yojson.Safe.t -> string -> string option
val default_compaction_profile : string
val canonical_compaction_profile : string -> string option
val parse_compaction_profile_opt :
  Yojson.Safe.t -> string -> (string option, string) result
val compaction_policy_of_profile : string -> float * int * int
val resolve_compaction_policy :
  profile_opt:string option ->
  ratio_opt:float option ->
  message_opt:int option ->
  token_opt:int option ->
  fallback_profile:string ->
  fallback_ratio:float ->
  fallback_message:int -> fallback_token:int -> string * float * int * int
val normalize_compaction_ratio_gate : float -> float
val normalize_compaction_message_gate : int -> int
val normalize_compaction_token_gate : int -> int
val normalize_continuity_compaction_cooldown_sec : int -> int
val default_keep_recent_tool_results : int
val default_tool_heavy_msg_threshold : int
val default_tool_heavy_ratio_floor : float
val keep_recent_tool_results_max : int
val normalize_keep_recent_tool_results : ?keeper_name:string -> int -> int
val normalize_proactive_idle_sec : int -> int
val normalize_proactive_cooldown_sec : int -> int
val keeper_compact_ratio : unit -> float
val keeper_compact_max_messages : unit -> int
val keeper_compact_max_tokens : unit -> int
val keeper_continuity_compaction_cooldown_sec : unit -> int
val keeper_compaction_policy_from_env : unit -> float * int * int
val keeper_bootstrap_proactive_warmup_sec : unit -> int
val keeper_bootstrap_stagger_step_sec : unit -> int
val keeper_bootstrap_retry_max : unit -> int
val keeper_bootstrap_retry_interval_sec : unit -> int
val keeper_proactive_min_cooldown_sec : unit -> int
val keeper_proactive_min_interval_sec : unit -> int
val keeper_proactive_task_cooldown_divisor : unit -> int
val keeper_proactive_task_min_cooldown_sec : unit -> int
val keeper_batch_limit : unit -> int
val keeper_board_debounce_window_sec : unit -> float
val keeper_tool_cost_max_usd : unit -> float option
val keeper_max_tools_per_turn : unit -> int
val keeper_retry_max_tools_per_turn : unit -> int
val keeper_board_event_limit : unit -> int
val keeper_llm_rerank_enabled : unit -> bool
val keeper_llm_rerank_cascade : unit -> string
val keeper_rule_reflect_repetition_threshold : unit -> float
val keeper_rule_plan_goal_alignment_threshold : unit -> float
val keeper_rule_plan_response_alignment_threshold : unit -> float
val keeper_rule_guardrail_repetition_threshold : unit -> float
val keeper_rule_guardrail_goal_alignment_threshold : unit -> float
val keeper_rule_guardrail_response_alignment_threshold : unit -> float
val keeper_rule_guardrail_context_threshold : unit -> float
val keeper_unified_temperature : unit -> float
val keeper_unified_max_tokens : unit -> int
val keeper_tool_search_top_k : unit -> int
val keeper_status_fast_default : unit -> bool
val keeper_slot_pool_size : unit -> int
val keeper_slot_id : string -> int option
val keeper_enable_thinking : unit -> bool
val keeper_adaptive_thinking_enabled : unit -> bool
val keeper_adaptive_thinking_mode : unit -> bool
val keeper_room_signal_prompt_enabled_override : unit -> bool option
val ensure_runtime_params_init : unit -> unit
type sandbox_profile =
  Keeper_types_profile_sandbox.sandbox_profile =
    Local
  | Docker
module Sandbox_profile_tla =
  Keeper_types_profile_sandbox.Sandbox_profile_tla
type network_mode =
  Keeper_types_profile_sandbox.network_mode =
    Network_none
  | Network_inherit
val to_tla_symbol : network_mode -> string
val all_symbols : string list
val all_states : network_mode list
val terminal_symbols : string list
val active_symbols : string list
val idle_symbols : string list
val is_terminal : network_mode -> bool
val is_active : network_mode -> bool
val is_idle : network_mode -> bool
val sandbox_profile_to_string : sandbox_profile -> string
val reserved_cascade_names : string list
val sandbox_profile_of_string : string -> sandbox_profile option
val all_sandbox_profiles : sandbox_profile list
val valid_sandbox_profile_strings : string list
val network_mode_to_string : network_mode -> string
val network_mode_of_string : string -> network_mode option
val all_network_modes : network_mode list
val valid_network_mode_strings : string list
val default_sandbox_profile : sandbox_profile
val default_network_mode_for_profile : sandbox_profile -> network_mode
type per_provider_timeout_state =
  Keeper_types_profile_defaults.per_provider_timeout_state =
    Per_provider_timeout_unset
  | Per_provider_timeout_invalid
  | Per_provider_timeout_set
type keeper_profile_defaults =
  Keeper_types_profile_defaults.keeper_profile_defaults = {
  id : Ids.Keeper_id.t option;
  manifest_path : string option;
  persona_name : string option;
  goal : string option;
  short_goal : string option;
  mid_goal : string option;
  long_goal : string option;
  will : string option;
  needs : string option;
  desires : string option;
  instructions : string option;
  autoboot_enabled : bool option;
  mention_targets : string list;
  proactive_enabled : bool option;
  proactive_idle_sec : int option;
  proactive_cooldown_sec : int option;
  room_signal_prompt_enabled : bool option;
  shards : string list option;
  allowed_paths : string list option;
  sandbox_profile :
    Keeper_types_profile_sandbox.sandbox_profile option;
  sandbox_image : string option;
  network_mode : Keeper_types_profile_sandbox.network_mode option;
  github_identity : string option;
  git_identity_mode : string option;
  tool_preset : string option;
  tool_preset_source : string option;
  tool_also_allow : string list option;
  tool_denylist : string list option;
  active_goal_ids : string list option;
  telemetry_feedback_enabled : bool option;
  telemetry_feedback_window_hours : int option;
  per_provider_timeout_state : per_provider_timeout_state;
  per_provider_timeout : float option;
  always_approve : bool option;
  social_model : string option;
  cascade_name : string option;
  models : string list option;
  max_turns_per_call : int option;
  max_turns_per_call_scheduled_autonomous : int option;
  oas_env : (string * string) list;
  unknown_toml_keys : string list;
}
val empty_keeper_profile_defaults : keeper_profile_defaults
type keeper_oas_context =
  Keeper_types_profile_defaults.keeper_oas_context = {
  env_pairs : (string * string) list;
  gemini_mcp_disabled : bool;
  gemini_approval_mode : string option;
  gemini_approval_mode_derived : bool;
  gemini_allowed_mcp_derived : bool;
  claude_mcp_config : string option;
}
val empty_keeper_oas_context : keeper_oas_context
val keeper_oas_context_of_defaults :
  keeper_profile_defaults -> keeper_oas_context
val dedupe_keep_order : 'a list -> 'a list
val normalize_name_list : string list -> string list
val normalize_name_list_opt : string list -> string list option
val normalize_cascade_name_opt : string option -> string option
val normalize_git_identity_mode_opt : string option -> string option
val normalize_social_model_opt : string option -> string option
val valid_social_model_strings : string list
val lower_string_list_opt : string list -> string list option
val valid_tool_preset_raw_strings : string list
val normalize_tool_preset_raw : string -> string option
val first_some : 'a option -> 'a option -> 'a option
val normalize_per_provider_timeout_opt :
  source:string -> float option -> float option
val per_provider_timeout_of_declared_float_opt :
  source:string ->
  declared:bool ->
  float option ->
  Keeper_types_profile_per_provider_timeout.per_provider_timeout_state *
  float option
val per_provider_timeout_of_toml :
  source:string ->
  Keeper_toml_loader.toml_doc ->
  string ->
  Keeper_types_profile_per_provider_timeout.per_provider_timeout_state *
  float option
val per_provider_timeout_of_json_field :
  source:string ->
  field:string ->
  Yojson.Safe.t ->
  Keeper_types_profile_per_provider_timeout.per_provider_timeout_state *
  float option
val normalize_per_provider_timeout_json_field :
  source:string -> field:string -> Yojson.Safe.t -> float option
val personas_root_opt : unit -> string option
val persona_profile_path_opt : string -> string option
