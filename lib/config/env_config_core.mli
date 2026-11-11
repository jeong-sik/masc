(** Env_config_core — MASC environment configuration prelude.

    All env vars use the [MASC_*] prefix. Functions ending in
    [_result] return [(string, string) result] for structured error
    handling; convenience variants without the suffix raise
    {!Config_error} on missing/invalid values.

    {b Runtime chain}: surface re-exposed via
    [include module type of Env_config_core] in
    {!Env_config}, which sibling sub-modules
    ({!Env_config_runtime}, {!Env_config_runtime_services},
    {!Env_config_keeper}) extend.  Sibling sub-modules also reach
    the helper getters here ([get_int], [get_float], [get_bool],
    [trim_opt], [raw_value_opt]) unqualified through the prelude
    pattern, so this boundary's surface flows through to every
    config consumer. *)

(** {1 Exception} *)

exception Config_error of string
(** Raised by convenience functions ([masc_http_base_url]) when a required
    environment variable is missing.  Prefer the [_result] variants for
    structured error handling. *)

(** {1 Raw env-var access} *)

val raw_value_opt : string -> string option
(** Read [name] via {!Sys.getenv_opt}, falling back to
    {!Config_boot_overrides} when the parent process did not export
    the variable.  Returns [None] when neither source has it.

    A name declared file-owned ({!Config_boot_overrides.declare_file_owned})
    never reads the process environment: only the boot override store answers. *)

(** {1 Typed getters with defaults} *)

val get_string : default:string -> string -> string
(** Unset or empty (including whitespace-only) gives [default], matching the
    other getters. Any other value is returned verbatim, without trimming. *)
type retention =
  | Retain_forever
  | Prune_after_days of int

val get_retention_days : default:retention -> string -> retention
(** Read a [MASC_*_RETENTION_DAYS] knob.

    Unset or empty gives [default], which each store declares for itself. A
    positive value prunes after that many days. Zero or negative keeps
    everything — the one way to say so, and it says it in every store.

    A malformed value gives [default] and warns, rather than meaning opposite
    things per store: two kept files forever and one began pruning at its own
    default, and each of the two cited the third as the model it followed
    (#27110). *)

val get_int : default:int -> string -> int
val get_float : default:float -> string -> float
val get_bool : default:bool -> string -> bool
val get_bool_strict : default:bool -> string -> bool
(** Like {!get_bool}, but a present non-empty malformed value always raises
    {!Config_error}. Missing and empty values still use [default]. Use at
    security-sensitive boundaries where warn-and-default would fail open. *)

val get_int_clamped : default:int -> min_v:int -> max_v:int -> string -> int
(** {!get_int} clamped into [[min_v, max_v]]. The canonical spelling of the
    parse-with-default-then-clamp read that several modules used to carry
    as local copies. *)

val get_float_clamped : default:float -> min_v:float -> max_v:float -> string -> float
(** {!get_float} clamped into [[min_v, max_v]]. Non-finite parses
    ([NaN], [+∞], [-∞]) fall back to [default] before clamping so
    [NaN] cannot propagate through {!Float.min} / {!Float.max}. *)

val get_int_nonneg : default:int -> string -> int
(** Like {!get_int} but floors negative parses at [default].  Use
    for env vars whose call sites treat negatives as nonsensical
    (retry caps, byte budgets, max counts).  NaN-equivalent for
    [int] does not exist, so the only extra rejection vs {!get_int}
    is [v < 0]. *)

val jsonl_retention_days : unit -> int
(** [MASC_JSONL_RETENTION_DAYS], default 30.  Day-file retention for the
    JSONL stores under [.masc], shared by the startup prune and the periodic
    maintenance prune. *)

val get_float_nonneg : default:float -> string -> float
(** Like {!get_float} but floors all non-finite (NaN, +∞, -∞) and
    negative parses at [default].  Use for env vars whose call
    sites treat negatives or non-finite values as nonsensical
    (timeouts, scores, ratios).  [+∞] is rejected because
    [float_of_string "inf"] succeeds and [+∞ > 0.0] would
    otherwise pass an effectively unbounded value through. *)

(** {1 String / path helpers} *)

val trim_opt : string option -> string option
(** [Some s] with whitespace trimmed; [None] when [s] is empty
    after trim or already [None]. *)

val strip_trailing_slashes : string -> string
val strip_path_trailing_slashes : string -> string
val expand_home_prefix : string -> string
(** A value that starts with ["~/"] with that prefix replaced by [HOME]; any
    other value, and a value with no [HOME] to read, unchanged. The one rule
    every config path that names a file under the operator's home shares. *)

val home_dir_opt : unit -> string option
(** [HOME] as {!expand_home_prefix} reads it: trimmed, [None] when unset or
    blank. *)

val expand_home_prefix_under : home:string option -> string -> string
(** {!expand_home_prefix} against the given home instead of the one read
    from the environment. A reader that keeps its result for later calls
    reads the home once, passes it here, and keeps it beside the result. *)

val normalize_path_lexically : string -> string
(** Trim and expand the home prefix, then reduce slash-separated empty, dot and
    parent components without consulting the filesystem. Relative paths retain
    leading parent components; absolute paths stop at their root. Already normalized
    paths may reuse the immutable input string. *)

val normalize_masc_base_path_input : string -> string
val existing_dir : string -> bool
val existing_file : string -> bool

(** {1 HTTP host + port (SSOT for issue 8352)} *)

val host_env_key : string
val http_port_env_key : string
val masc_http_port : unit -> string
val masc_http_port_int : unit -> int

val default_host : string
val masc_host : unit -> string

(** {1 HTTP base URL} *)

val http_base_url_env_key : string
val mcp_url_env_key : string
val masc_http_base_url_opt : unit -> string option
(** Return only an explicitly configured [MASC_HTTP_BASE_URL], normalized by
    trimming surrounding whitespace and trailing slashes.  Unlike
    {!masc_http_base_url_result}, this never derives an identity from
    [MASC_HOST]/[MASC_HTTP_PORT]; listener admission must use the actual bind
    configuration instead of re-reading potentially stale environment input. *)

val masc_http_base_url : unit -> string
val masc_http_base_url_result : unit -> (string, string) result

(** {1 Port helper} *)

val get_port : default:int -> string -> int
(** Read a TCP port from [name], validated to [\[1, 65535\]].
    Returns [default] on missing, empty, out-of-range, or
    non-integer values. *)

(** {1 Host pressure integration} *)

val host_fd_pressure_state_file_env_key : string
val host_fd_pressure_state_file_path_opt : unit -> string option
val host_fd_pressure_poller_disabled_env_key : string
val host_fd_pressure_poller_disabled : unit -> bool
val host_fd_pressure_poll_interval_sec_env_key : string
val host_fd_pressure_poll_interval_sec : unit -> float

(** {1 Base path / storage} *)

val base_path_env_key : string

type base_path_source =
  | From_env of string
  | From_persisted_default of string
      (** Path of the record file the installer wrote, not an env var. *)

val base_path_source_opt : unit -> (base_path_source * string) option
(** Resolution order: [MASC_BASE_PATH] > the workspace a past [masc setup]
    recorded. Explicit input always wins over the record.
    A record whose path holds no [.masc/config] directory is not used: [.masc]
    alone also exists under a home directory as the user skill source. *)

type persisted_default =
  | No_record
  | Usable of { record : string; base_path : string }
  | Stale of { record : string; recorded_path : string }
  | Unread_under_test of { record : string }

(** The [masc] directory of the config home of the user. [XDG_CONFIG_HOME]
    counts only when it is an absolute path, as the XDG Base Directory
    Specification asks; otherwise [HOME/.config]. Both values are trimmed, and
    an empty one is not set. [None] when neither gives one. *)
val masc_config_dir_of : xdg_config_home:string option -> home:string option -> string option

(** {!masc_config_dir_of} over [XDG_CONFIG_HOME] and [HOME]. The default base
    path record and the install record of the authorization store live here. *)
val masc_config_dir_opt : unit -> string option

(** [default-base-path] in {!masc_config_dir_opt}. *)
val default_base_path_record_path_opt : unit -> string option


val persisted_default_base_path : unit -> persisted_default
(** [Stale] is kept apart from [No_record] so the "not set" error can say that
    a recorded default was found and ignored, and why.

    [Unread_under_test] is the read counterpart of {!record_default_base_path}'s
    [Refused_under_test]: a test binary neither writes nor reads the record
    under the operator's HOME, so a suite cannot resolve a base path from
    whatever workspace the machine last named. A suite that means to exercise
    the record points [XDG_CONFIG_HOME] at a temp dir, which is not the
    operator's location and is both written and read. *)

type record_outcome =
  | Recorded of string
  | No_record_location
  | Refused_under_test
      (** A test executable asked. It never writes the operator's default:
          a suite that seeds a workspace in a temp dir would otherwise leave
          that path as the machine's default until the directory vanished. *)
  | Record_failed of { record : string; reason : string }
  | Not_a_workspace of { path : string }
      (** [path] holds no [.masc/config] directory, so the reader would ignore
          the record as stale; nothing is written. *)

val record_default_base_path : string -> record_outcome
(** Record the absolute canonical identity of the existing [path] as the
    default for later commands. Callers do this after the
    workspace has actually served a command, so a path that failed to boot is
    not remembered. Failure is returned, never raised: not recording a default
    must not fail the command that succeeded. *)

val base_path_not_set_message : unit -> string
(** The sentence both base-path reporters use when nothing resolved: this
    module and the workspace resolver in [lib/workspace]. Names the flag, the
    env var, and how to record a default; adds why a recorded default was
    ignored when one was found and is stale. *)

val running_under_test_executable : unit -> bool
val base_path_prod_guard : string -> string

val test_allow_real_docker_env : string
(** Name of the hook a refusal message tells the operator to set. The fake
    docker path's key stays private: callers want the value, not the name. *)

val fake_docker_path_opt : unit -> string option
(** The fake docker script a test asked for, or [None] when the variable is
    unset or blank. *)

val real_docker_allowed_under_test : unit -> bool
(** Whether a test executable said it may talk to the live docker daemon. *)
val base_path : unit -> string

val resolve_against_base_path : string -> string
(** [resolve_against_base_path raw] returns [raw] unchanged when it is
    absolute, and [Filename.concat (base_path ()) raw] when it is
    relative.  Raises [Config_error] through [base_path] when
    [MASC_BASE_PATH] is unset. *)

(** {1 Config dir} *)

val config_dir_env_key : string

(** {1 Auth} *)

val jsonl_retention_days_env_key : string
(** Named so [Env_config_snapshot] reports the knob without restating its
    spelling, the way {!admin_token_env_key} already is. *)

val admin_token_env_key : string
val admin_token_opt : unit -> string option

(** {1 Logging / telemetry} *)

val log_level_env_key : string
val log_routine_level_env_key : string
val telemetry_enabled_env_key : string

(** [MASC_PARSE_WARN]. Malformed env values always warn; this flag escalates
    them to a hard {!Config_error} (fail-fast boot). *)
val parse_warn_env_key : string

val telemetry_enabled : unit -> bool
