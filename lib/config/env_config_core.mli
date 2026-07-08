(** Env_config_core — MASC environment configuration prelude.

    All env vars use the [MASC_*] prefix. Functions ending in
    [_result] return [(string, string) result] for structured error
    handling; convenience variants without the suffix raise
    {!Config_error} on missing/invalid values.

    {b Runtime chain}: surface re-exposed via
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
(** Like {!get_float} but floors all non-finite (NaN, +∞, -∞) and
    negative parses at [default].  Use for env vars whose call
    sites treat negatives or non-finite values as nonsensical
    (timeouts, scores, ratios).  [+∞] is rejected because
    [float_of_string "inf"] succeeds and [+∞ > 0.0] would
    otherwise pass an effectively unbounded value through. *)

val get_ratio : default:float -> string -> float
(** Like {!get_float_nonneg} but additionally rejects parses [> 1.0].
    Use for env vars whose semantic is a fraction in [\[0, 1\]]:
    score thresholds, probabilities, context-ratio caps.

    The [default] argument is sanitised before clamping:
    non-finite defaults ([NaN], [+∞], [-∞]) are coerced to
    [0.0]; finite out-of-range defaults are clamped to
    [\[0, 1\]] via [Float.max 0.0 (Float.min 1.0 default)].
    [Float.min nan 1.0] propagates [NaN] in OCaml's IEEE 754
    semantics, so a naive clamp on its own would still leak
    [NaN]; the explicit {!Float.is_finite} check before
    clamping is what makes this helper [NaN]-safe.  Callers
    can rely on the return value always being a finite float
    in [\[0, 1\]]. *)

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

(* RFC-0085 PR-10 — [home_dir_opt] removed from the public surface;
   callers read from [(Host_config.from_env ()).home] instead.  The
   function is retained file-private because [base_path] /
   [sb_path_opt] still call it internally. *)

(* RFC-0085 PR-11 — Env var deprecation mechanism removed (7 entries:
   deprecation_warned, warn_deprecated, deprecated_opt,
   resolve_deprecated, get_float_deprecated, get_int_deprecated,
   get_bool_deprecated).  The sole MASC_KEEPER_AUTOBOT_MAX typo
   fallback caller is gone.  Future env
   migrations should pick a single name and stick with it; soft
   fallbacks accumulate via the workaround pattern from RFC-0084. *)

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

(* RFC-0085 PR-10 — [assets_dir_opt] removed completely.  Caller 0
   after PR-10 migration; readers use
   [(Host_config.from_env ()).assets_dir]. *)

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

(** {1 Host pressure integration} *)

val host_fd_pressure_state_file_env_key : string
val legacy_host_fd_pressure_state_file_env_key : string
val host_fd_pressure_poller_disabled_env_key : string
val host_fd_pressure_poll_interval_sec_env_key : string
val default_host_fd_pressure_state_file_path : string
val host_fd_pressure_state_file_path_opt : unit -> string option
val legacy_host_fd_pressure_state_file_path_opt : unit -> string option
val host_fd_pressure_state_file_path : unit -> string
val host_fd_pressure_poller_disabled : unit -> bool
val host_fd_pressure_poll_interval_sec : unit -> float

(** {1 Base path / storage} *)

val base_path_env_key : string
val base_path_input_env_key : string
val base_path_source_opt : unit -> (string * string) option

(* RFC-0085 PR-9 — [base_path_raw_opt] and [base_path_opt] are no
   longer part of the public surface.  External callers read the
   normalised env-derived base_path from
   [(Host_config.from_env ()).base_path] instead.  The two functions
   remain file-private inside [env_config_core.ml] because
   [base_path] / [sb_path_opt] still reach for the raw value
   internally; a follow-up RFC migrates those too. *)

val running_under_test_executable : unit -> bool
val test_allow_home_base_path_env : string
val base_path_prod_guard : string -> string
val base_path : unit -> string
val sb_path_opt : unit -> string option
val sb_path_result : unit -> (string, string) result
val sb_path : unit -> string
val orchestrator_enabled_env_key : string

(** {1 Config / personas / data dir} *)

val config_dir_env_key : string
val personas_dir_env_key : string

(* RFC-0085 PR-8 — [config_dir_opt] and [personas_dir_opt] removed
   from the public surface; callers now read these path values from
   [Host_config.from_env ()] (fields [config_dir] / [personas_dir]). *)

val data_dir_env_key : string
val data_dir_opt : unit -> string option

(** {1 Auth} *)

val admin_token_env_key : string
val admin_token_opt : unit -> string option

(** {1 Git} *)

val git_fetch_timeout_sec_env_key : string
val git_fetch_timeout_sec : unit -> float

(** {1 Logging / telemetry} *)

val log_level_env_key : string
val log_routine_level_env_key : string
val telemetry_enabled_env_key : string

(** [MASC_PARSE_WARN]. Malformed env values always warn; this flag escalates
    them to a hard {!Config_error} (fail-fast boot). *)
val parse_warn_env_key : string

val governance_level_env_key : string
val log_level_opt : unit -> string option
val telemetry_enabled : unit -> bool

(** Whether malformed env parses are escalated to {!Config_error} (fail-fast)
    instead of warn + default. Controlled by [MASC_PARSE_WARN]. Default: false. *)
val parse_warn_enabled : unit -> bool
val governance_level : unit -> string
val disable_hitl_env_key : string
val disable_hitl : unit -> bool

(** {1 Keeper Code-Execution Exemptions} *)

val code_exempt_keepers_env_key : string
val code_exempt_keeper : keeper_name:string -> bool

(** {1 Build identity / pubsub} *)

val build_git_commit_opt : unit -> string option
val pubsub_max_messages : unit -> int

(** {1 Keeper defaults} *)

val keeper_default_sandbox_profile_raw : unit -> string
