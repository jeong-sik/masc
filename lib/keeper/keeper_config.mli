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

val default_proactive_enabled : bool

(** Maximum bytes of personality text included in the rendered keeper prompt.
    Drives [normalize_prompt_text] when called from prompt rendering.
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

(** Validate a keeper name with the shared portable-name grammar. *)
val validate_name : string -> bool

val invalid_name_error : string -> string
(** Canonical explanation for a value rejected by {!validate_name}. *)

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

(** Trim and truncate prompt text to [max_bytes] on a UTF-8 character
    boundary. Caller MUST pass [max_bytes] explicitly so the unit is visible. *)
val normalize_prompt_text : max_bytes:int -> string -> string

(** {1 Compaction Configuration} *)

(** HOW a checkpoint is summarized (orthogonal to [profile], which decides
    WHEN to compact). [Llm] = provider-backed summarizer on the librarian
    lane (the default; summarizer failure always falls back to the
    deterministic chain); [Deterministic] = the extractive OAS strategy
    chain only (opt-out). *)
type compaction_mode =
  | Deterministic
  | Llm

val default_compaction_mode : compaction_mode
val compaction_mode_to_string : compaction_mode -> string

(** Parse a mode string; unknown → [Error] (never a permissive default). *)
val compaction_mode_of_string : string -> (compaction_mode, string) result

val keeper_compaction_mode_env_key : string

(** Global default mode from [MASC_KEEPER_COMPACTION_MODE]. Unset →
    [default_compaction_mode]; set-but-invalid → [invalid_arg] (fail-closed
    at load), mirroring the MASC_RUNTIME_ATTEMPT_LIVENESS precedent. *)
val keeper_compaction_mode_default : unit -> compaction_mode

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
val normalize_compaction_cooldown_sec : int -> int

(** {1 Runtime Parameters}

    These functions return the current runtime-tunable value.
    Each parameter is registered with [Runtime_params] and can be
    adjusted via the dashboard at runtime. *)

val keeper_compact_ratio : unit -> float
val keeper_compact_max_messages : unit -> int
val keeper_compact_max_tokens : unit -> int
val keeper_compaction_cooldown_sec : unit -> int
val keeper_compaction_policy_from_env : unit -> float * int * int

val keeper_bootstrap_proactive_warmup_sec : unit -> int
val keeper_bootstrap_stagger_step_sec : unit -> int
val keeper_bootstrap_retry_interval_sec : unit -> int

val keeper_batch_limit : unit -> int

val keeper_unified_temperature : unit -> float
val keeper_unified_max_tokens : unit -> int

(** {2 HITL Context-Summary Worker Policy} *)

val hitl_summary_temperature : unit -> float

val keeper_status_fast_default : unit -> bool

val keeper_enable_thinking : unit -> bool

(** {1 Runtime Param Handles}

    Exposed for test use only (e.g. [Runtime_params.clear]). *)

(** Force module initialization to guarantee all runtime params are registered
    before [Runtime_params.restore].  Call from server bootstrap. *)
val ensure_runtime_params_init : unit -> unit
