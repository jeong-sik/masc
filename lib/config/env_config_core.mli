(** Env_config_core — MASC environment configuration prelude.

    All env vars use the [MASC_*] prefix. Functions ending in
    [_result] return [(string, string) result] for structured error
    handling; convenience variants without the suffix raise
    {!Config_error} on missing/invalid values.

    {b Cascade chain}: surface re-exposed via
    [include module type of Env_config_core] in
    {!Env_config}, which sibling sub-modules
    ({!Env_config_runtime}, {!Env_config_governance},
    {!Env_config_keeper}) extend.  Sibling sub-modules also reach
    the helper getters here ([get_int], [get_float], [get_bool],
    [trim_opt], [raw_value_opt]) unqualified through the prelude
    pattern, so this boundary's surface flows through to every
    config consumer. *)

(** {1 Exception} *)

exception Config_error of string
(** Raised by convenience functions ([sb_path],
    [masc_http_base_url]) when a required environment variable is
    missing.  Prefer the [_result] variants for structured error
    handling. *)

(** {1 Raw env-var access} *)

val raw_value_opt : string -> string option
(** Read [name] via {!Sys.getenv_opt}, falling back to
    {!Config_boot_overrides} when the parent process did not export
    the variable.  Returns [None] when neither source has it. *)

(** {1 Typed getters with defaults} *)

val get_string : default:string -> string -> string
val get_int : default:int -> string -> int
val get_float : default:float -> string -> float
val get_bool : default:bool -> string -> bool

val get_int_nonneg : default:int -> string -> int
(** Like {!get_int} but floors negative parses at [default].  Use
    for env vars whose call sites treat negatives as nonsensical
    (retry caps, byte budgets, max counts).  NaN-equivalent for
    [int] does not exist, so the only extra rejection vs {!get_int}
    is [v < 0]. *)

val get_float_nonneg : default:float -> string -> float
(** Like {!get_float} but floors NaN and negative parses at
    [default].  Use for env vars whose call sites treat negatives
    or NaN as nonsensical (timeouts, scores, ratios). *)

(** {1 String / path helpers} *)

val trim_opt : string option -> string option
(** [Some s] with whitespace trimmed; [None] when [s] is empty
    after trim or already [None]. *)

val strip_trailing_slashes : string -> string
val strip_path_trailing_slashes : string -> string
val expand_home_prefix : string -> string
val normalize_path_lexically : string -> string
val normalize_masc_base_path_input : string -> string
val existing_dir : string -> bool
val existing_file : string -> bool
val home_dir_opt : unit -> string option

(** {1 Deprecation warnings + fallback getters} *)

val deprecation_warned : (string, bool) Hashtbl.t
(** Internal once-per-key cache for {!warn_deprecated}.  Exposed
    only because the cascade chain re-exports the prelude verbatim. *)

val warn_deprecated : old_name:string -> new_name:string -> unit

val deprecated_opt :
  old_name:string -> new_name:string -> string option

val resolve_deprecated :
  primary:string -> deprecated:string -> string option

val get_float_deprecated :
  default:float -> primary:string -> deprecated:string -> float

val get_int_deprecated :
  default:int -> primary:string -> deprecated:string -> int

val get_bool_deprecated :
  default:bool -> primary:string -> deprecated:string -> bool

(** {1 HTTP host + port (SSOT for issue 8352)} *)

val default_http_port : string
val default_http_port_int : int
val host_env_key : string
val http_port_env_key : string
val masc_http_port : unit -> string
val masc_http_port_int : unit -> int
val masc_host_opt : unit -> string option
val default_host : string
val masc_host : unit -> string

(** {1 Assets / cluster name} *)

val assets_dir_opt : unit -> string option
val cluster_name_opt : unit -> string option
val cluster_name : unit -> string

(** {1 HTTP base URL} *)

val http_base_url_env_key : string
val mcp_url_env_key : string
val masc_http_base_url : unit -> string
val masc_http_base_url_result : unit -> (string, string) result

(** {1 Port helper} *)

val get_port : default:int -> string -> int
(** Read a TCP port from [name], validated to [\[1, 65535\]].
    Returns [default] on missing, empty, out-of-range, or
    non-integer values. *)

(** {1 Base path / storage} *)

val base_path_env_key : string
val base_path_input_env_key : string
val base_path_source_opt : unit -> (string * string) option
val base_path_raw_opt : unit -> string option
val base_path_opt : unit -> string option
val running_under_test_executable : unit -> bool
val test_allow_home_base_path_env : string
val base_path_prod_guard : string -> string
val base_path : unit -> string
val sb_path_opt : unit -> string option
val sb_path_result : unit -> (string, string) result
val sb_path : unit -> string
val storage_type_env_key : string
val orchestrator_enabled_env_key : string
val storage_type : unit -> string

(** {1 Config / personas / data dir} *)

val config_dir_env_key : string
val personas_dir_env_key : string
val config_dir_opt : unit -> string option
val personas_dir_opt : unit -> string option
val data_dir_env_key : string
val data_dir_opt : unit -> string option

(** {1 Relay calibration} *)

val relay_calibration_enabled : unit -> bool

(** {1 Auth} *)

val admin_token_env_key : string
val tool_auth_strict_env_key : string
val admin_token_opt : unit -> string option
val tool_auth_strict : unit -> bool

(** {1 Git} *)

val git_fetch_timeout_sec_env_key : string
val git_fetch_timeout_sec : unit -> float

(** {1 Logging / telemetry} *)

val log_level_env_key : string
val log_routine_level_env_key : string
val telemetry_enabled_env_key : string
val parse_warn_env_key : string
val governance_level_env_key : string
val log_level_opt : unit -> string option
val telemetry_enabled : unit -> bool
val parse_warn_enabled : unit -> bool
val governance_level : unit -> string

(** {1 Build identity / auto respond / pubsub} *)

val build_git_commit_opt : unit -> string option
val auto_respond_opt : unit -> string option
val pubsub_max_messages : unit -> int

(** {1 Keeper defaults} *)

val keeper_social_model : unit -> string
val keeper_will : unit -> string
val keeper_needs : unit -> string
val keeper_desires : unit -> string
val keeper_default_sandbox_profile_raw : unit -> string
