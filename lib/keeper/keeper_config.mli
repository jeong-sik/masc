(** Keeper configuration — defaults, environment variable parsing, profiles.

    Central SSOT for keeper runtime constants, environment variable parsing,
    compaction profiles, and runtime parameter registrations.

    @since v2.128.0 *)

(** {1 Core Constants} *)

(** Default cascade name for keeper turns.  All keeper code must reference
    this constant instead of using the string literal.
    @since v2.128.0 *)
val default_cascade_name : string

(** Cascade name for recovery turns (Failing phase).
    @since Core Triad *)
val local_recovery_cascade_name : string

(** Cascade name for buffer operations (Compacting, HandingOff).
    @since Core Triad *)
val local_only_cascade_name : string

(** Minimum context window (tokens) for any keeper turn. *)
val min_keeper_context_tokens : int

(** {2 Alert Preview Truncation Lengths}

    Invariant: [excerpt_min < message_max < reply_max]. *)

val alert_error_detail_max_chars : int
val alert_excerpt_min_chars : int
val alert_message_preview_max_chars : int
val alert_reply_preview_max_chars : int

(** {2 Tool Policy Display Thresholds} *)

val tool_policy_count_warn_threshold : int
val tool_first_sentence_max_chars : int
val default_proactive_enabled : bool
val default_proactive_idle_sec : int
val default_proactive_cooldown_sec : int
val default_room_signal_prompt_enabled : bool
val default_goal_horizon_max_chars : int
val default_drift_max_clauses : int
val default_drift_max_chars : int

(** {1 Environment Variable Parsing} *)

(** Parse a boolean env var where the default is [true] when unset. *)
val bool_default_true_of_env : string -> bool

(** Parse a boolean env var with an explicit default.
    Recognizes 1/true/yes/y/on and 0/false/no/n/off. *)
val bool_of_env_default : string -> default:bool -> bool

(** Parse a boolean env var, returning [None] when unset or unrecognized. *)
val bool_of_env_opt : string -> bool option

(** Parse an integer env var with default and clamping. *)
val int_of_env_default : string -> default:int -> min_v:int -> max_v:int -> int

(** Parse a float env var with default and clamping. *)
val float_of_env_default : string -> default:float -> min_v:float -> max_v:float -> float

(** Clamp an integer to [min_v, max_v]. *)
val clamp_int : int -> min_v:int -> max_v:int -> int

(** {1 Name Validation} *)

(** Validate a keeper name: non-empty, alphanumeric with dots, dashes, underscores. *)
val validate_name : string -> bool

(** {1 Removed Key Detection} *)

(** Field names that are no longer accepted in keeper creation/update input. *)
val removed_keeper_input_key_names : string list

(** Field names that are no longer accepted in keeper message input. *)
val removed_keeper_msg_input_key_names : string list

(** Field names that are no longer accepted in keeper metadata. *)
val removed_keeper_meta_key_names : string list

(** Return which [keys] are present as top-level keys in the JSON object. *)
val present_json_keys : string list -> Yojson.Safe.t -> string list

(** Reject removed keeper input keys.  Returns [Error msg] listing the offending fields. *)
val reject_removed_keeper_input_keys :
  tool_name:string -> Yojson.Safe.t -> (unit, string) result

(** Reject removed keeper message input keys. *)
val reject_removed_keeper_msg_input_keys :
  tool_name:string -> Yojson.Safe.t -> (unit, string) result

(** {1 UTF-8 Safety} *)

(** Truncate a string to at most [max_bytes] bytes on a valid UTF-8 boundary. *)
val utf8_safe_prefix_bytes : string -> max_bytes:int -> string

(** Replace invalid UTF-8 sequences with U+FFFD. *)
val utf8_repair_string : string -> string

(** {1 Text Normalization} *)

val normalize_self_model_text : ?max_len:int -> string -> string
val normalize_goal_horizon_text : ?max_len:int -> string -> string
val normalize_goal_horizon_opt : string option -> string option
val parse_goal_horizon_opt : Yojson.Safe.t -> string -> string option

(** Resolve short/mid/long goal horizons with fallback to [goal]. *)
val resolve_goal_horizons :
  goal:string ->
  short_goal_opt:string option ->
  mid_goal_opt:string option ->
  long_goal_opt:string option ->
  string * string * string

val split_semicolon_clauses : string -> string list
val take_last : int -> 'a list -> 'a list

(** Compact self-model text: take last N clauses, truncate to max chars. *)
val compact_self_model_text :
  ?max_clauses:int -> ?max_chars:int -> string -> string

val parse_self_model_opt : Yojson.Safe.t -> string -> string option

(** {1 Compaction Configuration} *)

val default_compaction_profile : string
val canonical_compaction_profile : string -> string option
val parse_compaction_profile_opt :
  Yojson.Safe.t -> string -> (string option, string) result

(** Return (ratio, message_gate, token_gate) for a named profile. *)
val compaction_policy_of_profile : string -> float * int * int

(** Resolve compaction policy from explicit overrides with profile-based fallbacks. *)
val resolve_compaction_policy :
  profile_opt:string option ->
  ratio_opt:float option ->
  message_opt:int option ->
  token_opt:int option ->
  fallback_profile:string ->
  fallback_ratio:float ->
  fallback_message:int ->
  fallback_token:int ->
  string * float * int * int

val normalize_compaction_ratio_gate : float -> float
val normalize_compaction_message_gate : int -> int
val normalize_compaction_token_gate : int -> int
val normalize_continuity_compaction_cooldown_sec : int -> int

val normalize_proactive_idle_sec : int -> int
val normalize_proactive_cooldown_sec : int -> int

(** {1 Runtime Parameters}

    These functions return the current runtime-tunable value.
    Each parameter is registered with [Runtime_params] and can be
    adjusted via the dashboard at runtime. *)

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
val keeper_proactive_task_cooldown_divisor : unit -> int
val keeper_proactive_task_min_cooldown_sec : unit -> int

val keeper_batch_limit : unit -> int
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

val keeper_llama_slots : unit -> int

(** Compute a deterministic slot_id for a keeper name.
    Returns [None] when slot pinning is disabled. *)
val keeper_slot_id : string -> int option

val keeper_enable_thinking : unit -> bool
val keeper_adaptive_thinking_enabled : unit -> bool

(** When true, each turn's [enable_thinking] boolean is chosen per turn by
    [Keeper_turn_intent.classify] (Mechanical → false, Cognitive → true)
    and injected via the [before_turn_params] hook. When false, the static
    [keeper_enable_thinking ()] base is used for every turn.

    Independent of [keeper_adaptive_thinking_enabled] (which only tunes
    the thinking budget, not the on/off choice). *)
val keeper_adaptive_thinking_mode : unit -> bool

(** {1 Runtime Param Handles}

    Exposed for test use only (e.g. [Runtime_params.clear]). *)

(** Coord signal prompt enabled override from env var. *)
val keeper_room_signal_prompt_enabled_override : unit -> bool option

(** Force module initialization to guarantee all runtime params are registered
    before [Runtime_params.restore].  Call from server bootstrap. *)
val ensure_runtime_params_init : unit -> unit
