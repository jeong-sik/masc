(** Keeper configuration — defaults, environment variable parsing, profiles.

    Central SSOT for keeper runtime constants, environment variable parsing,
    compaction profiles, and runtime parameter registrations.

    @since v2.128.0 *)

(** {1 Core Constants} *)

(** Default runtime name for keeper turns = the default Runtime's id.

    runtime→Runtime 숙청: 이전의 phase_recovery / phase_buffer /
    tool_action / phase_routing 구분은 모두 동일한 default Runtime 으로
    수렴하는 죽은 추상화였으므로 이 단일 thunk 로 collapse 되었다.
    @since v2.128.0
    @since RFC-0066 Phase 1: changed from a string value to a thunk
    (issue #14624). *)
val default_runtime_id : unit -> string

(** Minimum context window (tokens) for any keeper turn. *)
val min_keeper_context_tokens : int

(** Maximum context window (tokens) accepted for [max_context_override].
    Matches the largest published context window among supported
    providers (Claude Opus 4.7 / Sonnet 4.6 = 1M).  #9953 SSOT — do not
    re-hardcode [1_000_000] elsewhere. *)
val max_keeper_context_tokens : int

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
val approval_queue_stale_max_wait_sec : float
val default_goal_max_chars : int
val default_drift_max_clauses : int

(** Maximum bytes of personality text included in the rendered keeper prompt.
    Drives [normalize_self_model_text] when called from prompt rendering.
    NOTE: persistence layer does NOT enforce this — disk JSON may hold
    longer values; the cap applies at prompt build time. *)
val prompt_render_max_bytes : int

(** {1 Environment Variable Parsing} *)

(** Parse a boolean env var where the default is [true] when unset. *)
val bool_default_true_of_env : string -> bool

(** Parse a boolean env var with an explicit default.
    Recognizes 1/true/yes/y/on and 0/false/no/n/off. *)
val bool_of_env_default : string -> default:bool -> bool

(** Parse a boolean env var, returning [None] when unset or unrecognized. *)
val bool_of_env_opt : string -> bool option

(** Parse a raw string as a boolean.
    Recognizes 1/true/yes/y/on and 0/false/no/n/off (case-insensitive).
    Returns [None] for other values. Shared parsing logic for
    [bool_of_env_default] and [bool_of_env_opt]. *)
val bool_of_string : string -> bool option

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

(** Return which [keys] are present as top-level keys in the JSON object. *)
val present_json_keys : string list -> Yojson.Safe.t -> string list

(** Reject removed keeper input keys.  Returns [Error msg] listing the offending fields. *)
val reject_removed_keeper_input_keys :
  ?allow_sandbox_fields:bool ->
  tool_name:string ->
  Yojson.Safe.t ->
  (unit, string) result

(** Reject removed keeper message input keys. *)
val reject_removed_keeper_msg_input_keys :
  tool_name:string -> Yojson.Safe.t -> (unit, string) result

(** {1 UTF-8 Safety} *)

(** Replace invalid UTF-8 sequences with U+FFFD. *)
val utf8_repair_string : string -> string

(** {1 Text Normalization} *)

(** Trim and truncate self-model text (will/needs/desires) to [max_bytes]
    on a UTF-8 character boundary. Caller MUST pass [max_bytes] explicitly so
    the unit (bytes, not chars) is visible at every call site. *)
val normalize_self_model_text : max_bytes:int -> string -> string
val normalize_goal_text : ?max_len:int -> string -> string

val split_semicolon_clauses : string -> string list
val take_last : int -> 'a list -> 'a list

(** Compact self-model text: take last N clauses, truncate to [max_bytes]. *)
val compact_self_model_text :
  ?max_clauses:int -> max_bytes:int -> string -> string

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

(** Default number of recent tool results to keep verbatim during
    OAS context compaction.  Preserves prior hardcoded [keep_recent:2]
    behavior in [Keeper_compact_policy]. *)
val default_keep_recent_tool_results : int

(** Hard upper bound for operator-supplied
    [keep_recent_tool_results] (typo guard). *)
val keep_recent_tool_results_max : int

(** Clamp [keep_recent_tool_results] to [[0, keep_recent_tool_results_max]].
    Out-of-range values fall back to {!default_keep_recent_tool_results}
    with a [Log.Keeper.warn] including [keeper_name] when supplied. *)
val normalize_keep_recent_tool_results : ?keeper_name:string -> int -> int

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
val keeper_proactive_min_interval_sec : unit -> int
val keeper_proactive_task_cooldown_divisor : unit -> int
val keeper_proactive_task_min_cooldown_sec : unit -> int

val keeper_batch_limit : unit -> int
val keeper_llm_rerank_enabled : unit -> bool
val keeper_llm_rerank_runtime : unit -> string
(** Reranker runtime profile. Defaults through [routes.llm_rerank]; env
    overrides may be either a concrete profile name or a logical route key. *)

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

val keeper_enable_thinking : unit -> bool
val keeper_adaptive_thinking_enabled : unit -> bool

(** {1 Runtime Param Handles}

    Exposed for test use only (e.g. [Runtime_params.clear]). *)

(** Force module initialization to guarantee all runtime params are registered
    before [Runtime_params.restore].  Call from server bootstrap. *)
val ensure_runtime_params_init : unit -> unit
