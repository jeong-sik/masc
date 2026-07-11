(** MASC Environment Configuration

    Centralized environment variable management following 12-Factor App principles.
    All env vars use MASC_* prefix for consistency.

    Functions ending in [_result] return [(string, string) result] and are
    the preferred API.  Convenience functions without [_result] suffix raise
    {!Config_error} on missing/invalid environment variables.

    Usage:
      let threshold = Env_config.Zombie.threshold_seconds
      let lock_timeout = Env_config.Lock.timeout_seconds
*)

(** Raised by convenience functions ([sb_path],
    [masc_http_base_url]) when a required environment variable is missing.
    Prefer the [_result] variants for structured error handling. *)
exception Config_error of string

let () = Printexc.register_printer (function
  | Config_error msg -> Some (Printf.sprintf "Env_config_core.Config_error: %s" msg)
  | _ -> None)

let raw_value_opt name =
  match Unix.getenv name with
  | v -> Some v
  | exception Not_found ->
    match Sys.getenv_opt name with
    | Some _ as value -> value
    | None -> Config_boot_overrides.get_opt name

(* [MASC_PARSE_WARN] governs strict mode below. Defined here (rather than with
   the other env-key constants further down) so the malformed handler can see
   it. *)
let parse_warn_env_key = "MASC_PARSE_WARN"

(* Strict mode: when [MASC_PARSE_WARN] is truthy a malformed env value becomes a
   hard [Config_error] (fail-fast boot) instead of warn + default. Read with a
   primitive truthy check rather than [get_bool] so a malformed value for this
   very key cannot recurse back into [reject_malformed_env]. *)
let parse_strict_mode () =
  match raw_value_opt parse_warn_env_key with
  | Some v ->
    (match String.trim v |> String.lowercase_ascii with
     | "true" | "1" | "yes" | "on" -> true
     | _ -> false)
  | None -> false

(* A non-empty env value that does not parse to the expected type is an operator
   misconfiguration, not a silent fallback. Loud by default: warn and use
   [default]. [MASC_PARSE_WARN] escalates to [Config_error] for fail-fast boot.
   The empty string is handled by each caller as "unset" (silent default) — an
   empty env var is a common intentional no-op. *)
let reject_malformed_env ~name ~raw ~type_name =
  Log.Misc.warn "malformed env %s=%S (expected %s); using default" name raw
    type_name;
  if parse_strict_mode () then
    raise
      (Config_error
         (Printf.sprintf "malformed env %s=%S (expected %s)" name raw type_name))

(** Safe getters with defaults *)
let get_string ~default name =
  match raw_value_opt name with
  | Some v -> v
  | None -> default

let get_int ~default name =
  match raw_value_opt name with
  | None -> default
  | Some v ->
    if String.trim v = "" then default
    else (
      match Safe_ops.int_of_string_safe v with
      | Some n -> n
      | None ->
        reject_malformed_env ~name ~raw:v ~type_name:"int";
        default)

let get_float ~default name =
  match raw_value_opt name with
  | None -> default
  | Some v ->
    if String.trim v = "" then default
    else (
      match Safe_ops.float_of_string_safe v with
      | Some f -> f
      | None ->
        reject_malformed_env ~name ~raw:v ~type_name:"float";
        default)

(** Variants that floor at zero.  An operator who sets a negative
    value (e.g. [MASC_KEEPER_MEMORY_MAX_NOTES=-5]) gets the default
    rather than the literal — negative budgets/counts are
    nonsensical for the call sites these feed
    ({!Env_config_keeper}, size budgets, retry caps).

    For the float variant, all non-finite values (NaN, +∞, -∞) are
    also rejected.  [+∞] sneaks past the [< 0.0] check because
    [infinity > 0.0] is [true], but for timeout/score/ratio
    settings [+∞] is just as nonsensical as [NaN].  [-∞ < 0.0] is
    [true] so it would already fall through, but using
    {!Float.is_finite} as the single guard captures all three
    pathological values uniformly. *)
let get_int_nonneg ~default name =
  let parsed = get_int ~default name in
  if parsed < 0 then default else parsed

let get_float_nonneg ~default name =
  let parsed = get_float ~default name in
  if (not (Float.is_finite parsed)) || parsed < 0.0 then default
  else parsed

(** Variant for [\[0.0, 1.0\]]-bounded floats — probabilities,
    score thresholds, context-ratio caps, anything where the
    operator's mental model is "this is a fraction".  Implemented
    by delegating to {!get_float_nonneg} (which already handles
    NaN/-∞ rejection and the negative-floor semantics) and then
    adding the [> 1.0] upper bound.

    The [default] itself is sanitised first: non-finite inputs
    ([NaN], [+∞], [-∞]) are coerced to [0.0]; finite values
    out of range are clamped via [Float.max 0.0 (Float.min 1.0 .)].
    This is defense in depth so a caller passing a stale
    out-of-range default still gets a valid ratio back.

    NaN-safety note: [Float.min nan 1.0] / [Float.max nan 0.0]
    propagate NaN per OCaml's IEEE 754 semantics, so a naive
    [Float.max 0.0 (Float.min 1.0 v)] without the explicit
    {!Float.is_finite} guard would still leak NaN. *)
let get_ratio ~default name =
  let sanitise v =
    if not (Float.is_finite v) then 0.0
    else Float.max 0.0 (Float.min 1.0 v)
  in
  let safe_default = sanitise default in
  (* Delegate to get_float_nonneg for the < 0.0 / non-finite
     rejection, then layer the > 1.0 upper bound. *)
  let parsed = get_float_nonneg ~default:safe_default name in
  if parsed > 1.0 then safe_default else parsed

let get_bool ~default name =
  match raw_value_opt name with
  | None -> default
  | Some v ->
      (match String.trim v |> String.lowercase_ascii with
       | "true" | "1" | "yes" | "on" -> true
       | "false" | "0" | "no" | "off" -> false
       | "" -> default
       | _ ->
           reject_malformed_env ~name ~raw:v ~type_name:"bool";
           default)

let trim_opt = function
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed
  | None -> None

let strip_trailing_slashes value =
  let rec loop idx =
    if idx <= 0 then ""
    else if value.[idx - 1] = '/' then loop (idx - 1)
    else String.sub value 0 idx
  in
  loop (String.length value)

let strip_path_trailing_slashes value =
  let trimmed = String.trim value in
  let rec loop current =
    let len = String.length current in
    if len > 1 && current.[len - 1] = '/' then
      loop (String.sub current 0 (len - 1))
    else
      current
  in
  if trimmed = "" then "" else loop trimmed

let expand_home_prefix value =
  if String.length value >= 2 && value.[0] = '~' && value.[1] = '/' then
    match raw_value_opt "HOME" |> trim_opt with
    | Some home -> Filename.concat home (String.sub value 2 (String.length value - 2))
    | None -> value
  else
    value

let normalize_path_lexically value =
  let value = expand_home_prefix (String.trim value) in
  if value = "" then ""
  else
    let absolute = value.[0] = '/' in
    let parts = String.split_on_char '/' value in
    let rec fold acc = function
      | [] -> acc
      | "" :: rest | "." :: rest -> fold acc rest
      | ".." :: rest -> (
          match acc, absolute with
          | _ :: acc_tail, _ -> fold acc_tail rest
          | [], true -> fold [] rest
          | [], false -> fold [ ".." ] rest)
      | part :: rest -> fold (part :: acc) rest
    in
    let normalized_parts = List.rev (fold [] parts) in
    match absolute, normalized_parts with
    | true, [] -> "/"
    | true, parts -> "/" ^ String.concat "/" parts
    | false, [] -> "."
    | false, parts -> String.concat "/" parts

let normalize_masc_base_path_input path =
  let normalized = path |> normalize_path_lexically |> strip_path_trailing_slashes in
  if normalized = "" then ""
  else if String.equal (Filename.basename normalized) Common.masc_dirname then
    match Filename.dirname normalized with
    | "" -> "."
    | parent -> parent
  else
    normalized

let existing_dir path =
  Sys.file_exists path && Sys.is_directory path

let existing_file path =
  Sys.file_exists path && not (Sys.is_directory path)

let home_dir_opt () =
  raw_value_opt "HOME" |> trim_opt

(* RFC-0085 PR-11 — Env var deprecation mechanism removed.

   The deprecation_warned Hashtbl + warn_deprecated + deprecated_opt +
   resolve_deprecated + get_{float,int,bool}_deprecated cluster had a
   single caller for the MASC_KEEPER_AUTOBOT_MAX typo legacy is gone. Per
   memory/feedback_hardcoding_and_legacy_zero_tolerance.md, legacy env
   support is deleted at the same time as the mechanism that hosts it;
   the typo env is no longer recognised and operators using it must
   migrate to MASC_KEEPER_AUTOBOOT_MAX. *)


let default_http_port = Masc_network_defaults.masc_http_default_port_s
let default_http_port_int = Masc_network_defaults.masc_http_default_port

(** SSOT for MASC_HOST / MASC_HTTP_PORT env-var names (issue 8352).
    Defined here so in-process readers and out-of-process callers
    (snapshot, provider_adapter presence check, bootstrap putenv)
    share one literal. *)
let host_env_key = "MASC_HOST"
let http_port_env_key = "MASC_HTTP_PORT"

let masc_http_port () =
  match raw_value_opt http_port_env_key |> trim_opt with
  | Some port -> port
  | None -> Masc_network_defaults.masc_http_default_port_s

let masc_http_port_int () =
  Safe_ops.int_of_string_with_default
    ~default:Masc_network_defaults.masc_http_default_port (masc_http_port ())

let masc_host_opt () =
  raw_value_opt host_env_key |> trim_opt

let default_host = Masc_network_defaults.masc_http_default_host

(** Centralized MASC_HOST reader.
    Reads MASC_HOST env var.
    Default: {!default_host} ("127.0.0.1"). *)
let masc_host () =
  match masc_host_opt () with
  | Some host -> host
  | None -> default_host

(* RFC-0085 PR-10 — [assets_dir_opt] removed (caller 0 after migration).
   Readers use [(Host_config.from_env ()).assets_dir]. *)

let cluster_name_opt () =
  raw_value_opt "MASC_CLUSTER_NAME" |> trim_opt

(** Centralized MASC_CLUSTER_NAME reader.
    Default: "default". All call sites should use this instead of
    reading Sys.getenv_opt "MASC_CLUSTER_NAME" directly. *)
let cluster_name () =
  match cluster_name_opt () with
  | Some name -> name
  | None -> "default"

(** SSOT for the MASC_HTTP_BASE_URL env-var name (issue 8352).
    Defined here (above [masc_http_base_url]) so the constant is in scope
    before first use. *)
let http_base_url_env_key = "MASC_HTTP_BASE_URL"
let mcp_url_env_key = "MASC_URL"

let rec masc_http_base_url () =
  match masc_http_base_url_result () with
  | Ok base -> base
  | Error msg -> raise (Config_error msg)

and masc_http_base_url_result () =
  match raw_value_opt http_base_url_env_key |> trim_opt with
  | Some base -> Ok (strip_trailing_slashes base)
  | None ->
      let host =
        match masc_host_opt () with
        | Some value -> Ok value
        | None ->
            Error
              "MASC_HTTP_BASE_URL is required (or set MASC_HOST with MASC_HTTP_PORT)"
      in
      Result.map
        (fun host -> Printf.sprintf "http://%s:%s" host (masc_http_port ()))
        host

(** {1 Additional Helpers} *)

(** Read a TCP port from env, validated to [1, 65535]. Returns default on
    missing, empty, out-of-range, or non-integer values. *)
let get_port ~default name =
  match raw_value_opt name |> trim_opt with
  | Some s -> (
      match int_of_string_opt s with
      | Some p when p > 0 && p < 65536 -> p
      | _ -> default)
  | None -> default

(** {1 Host pressure integration} *)

let host_fd_pressure_state_file_env_key = "MASC_HOST_FD_PRESSURE_STATE_FILE"
let legacy_host_fd_pressure_state_file_env_key = "MASC_SYSMON_PRESSURE_STATE"
let host_fd_pressure_poller_disabled_env_key = "MASC_HOST_FD_PRESSURE_POLLER_DISABLED"
let host_fd_pressure_poll_interval_sec_env_key = "MASC_HOST_FD_PRESSURE_POLL_INTERVAL_SEC"
let default_host_fd_pressure_state_file_path = Filename.get_temp_dir_name () ^ "/masc-host-pressure.state"

let host_fd_pressure_state_file_path_opt () =
  raw_value_opt host_fd_pressure_state_file_env_key |> trim_opt

let legacy_host_fd_pressure_state_file_path_opt () =
  raw_value_opt legacy_host_fd_pressure_state_file_env_key |> trim_opt

let host_fd_pressure_state_file_path () =
  match host_fd_pressure_state_file_path_opt () with
  | Some path -> path
  | None ->
    (match legacy_host_fd_pressure_state_file_path_opt () with
     | Some path -> path
     | None -> default_host_fd_pressure_state_file_path)
;;

(** Operator policy toggle for disabling host fd pressure polling.
    @category Policies
    @ops_class operator *)
let host_fd_pressure_poller_disabled () =
  get_bool ~default:false host_fd_pressure_poller_disabled_env_key

(** Operator timeout/interval knob for host fd pressure polling cadence.
    @category Timeouts
    @ops_class operator *)
let host_fd_pressure_poll_interval_sec () =
  get_float ~default:1.0 host_fd_pressure_poll_interval_sec_env_key
  |> Float.max 0.5
  |> Float.min 60.0

(** {1 Core Path / Storage} *)

(** Env var names exposed as SSOT constants so out-of-process callers
    that read/write the variable by name (docker worker putenv, sidecar
    lookup, config auth diagnostics, runtime-bootstrap putenv) can
    reference the same literal. Issue 8352. *)
let base_path_env_key = "MASC_BASE_PATH"
let base_path_input_env_key = "MASC_BASE_PATH_INPUT"
(* http_base_url_env_key is defined above (before masc_http_base_url) so the
   SSOT constant is in scope at first use. *)

(** Project base path for .masc data directory.
    Used by board, checkpoint, thompson_sampling, voice, keeper.
    Set at startup; may be overridden from inside the running process via
    [Unix.putenv] before use. Parent-shell env edits do not affect an already
    running server.
    Returns None when MASC_BASE_PATH is unset or empty. *)
let base_path_source_opt () =
  match raw_value_opt base_path_input_env_key |> trim_opt with
  | Some value -> Some (base_path_input_env_key, value)
  | None ->
      (match raw_value_opt base_path_env_key |> trim_opt with
       | Some value -> Some (base_path_env_key, value)
       | None -> None)

let base_path_raw_opt () =
  match base_path_source_opt () with
  | Some (_name, value) -> Some value
  | None -> None

let base_path_opt () =
  base_path_raw_opt () |> Option.map normalize_masc_base_path_input

(** [running_under_test_executable ()] mirrors the convention in
    {!Config_dir_resolver}: the process's [Sys.executable_name]
    basename starts with ["test_"]. Used to gate production-path
    safeguards. *)
let running_under_test_executable () =
  let basename =
    Sys.executable_name |> Filename.basename |> String.lowercase_ascii
  in
  String.length basename >= 5 && String.starts_with ~prefix:"test_" basename

(** #9903: production base-path safeguard for test executables.

    Without this, a test whose [MASC_BASE_PATH] override fails to
    take effect (due to any combination of dune env precedence,
    module init-time caching, or Eio.Path absolute-path
    interpretation) silently falls through to the operator's HOME
    and appends fixture data to the live ledger — the exact
    failure mode diagnosed on [<base-path>/.masc/board_votes.jsonl]
    (112 hot-voter-* rows overwrote real keeper votes).

    The safeguard is lossy by design: a test that resolves
    [base_path] to a [HOME] prefix raises [Config_error]
    immediately. Loss of a test run is strictly better than loss
    of production data.

    Escape hatch: set [MASC_TEST_ALLOW_HOME_BASE_PATH=1] for tests
    that legitimately need HOME-relative paths (none known today;
    the env var exists only so a reviewer can turn it on
    temporarily while investigating a new breach).

    Non-test executables (the MCP server) skip the check — HOME
    fallback is the correct production behavior. *)
let test_allow_home_base_path_env = "MASC_TEST_ALLOW_HOME_BASE_PATH"

let base_path_prod_guard path =
  if not (running_under_test_executable ()) then path
  else begin
    let allow =
      match raw_value_opt test_allow_home_base_path_env |> trim_opt with
      | Some v -> v = "1" || v = "true"
      | None -> false
    in
    if allow then path
    else
      match home_dir_opt () with
      | None -> path
      | Some home ->
        let home_norm = normalize_masc_base_path_input home in
        if home_norm <> "" && String.length path >= String.length home_norm
           && String.sub path 0 (String.length home_norm) = home_norm
        then
          raise (Config_error
            (Printf.sprintf
               "#9903 test isolation breach: Env_config_core.base_path() \
                resolved to %S under HOME=%S in test executable %S. This \
                indicates a MASC_BASE_PATH override failure — writing to \
                the production ledger under HOME would corrupt real data. \
                Fix the override path in the test, or set \
                MASC_TEST_ALLOW_HOME_BASE_PATH=1 to bypass (not \
                recommended)."
               path home_norm (Filename.basename Sys.executable_name)))
        else path
  end

(** Project base path. [MASC_BASE_PATH] is required. *)
let base_path () =
  match base_path_opt () with
  | Some path -> base_path_prod_guard path
  | None ->
      raise (Config_error
        "MASC_BASE_PATH is not set. Set MASC_BASE_PATH to the project root \
         containing the .masc/ directory.")

let sb_path_opt () =
  match base_path_opt () with
  | Some root ->
      let path = Filename.concat root "scripts/sb" in
      if existing_file path then Some path else None
  | None -> None

let sb_path_result () =
  match sb_path_opt () with
  | Some path -> Ok path
  | None ->
      Error
        "Unable to resolve scripts/sb. Set MASC_BASE_PATH."

let sb_path () =
  match sb_path_result () with
  | Ok path -> path
  | Error msg -> raise (Config_error msg)

(** SSOT for the MASC_ORCHESTRATOR_ENABLED env-var name (issue 8352).
    Referenced by feature_flag_registry catalog, env_config_runtime reader,
    env_config_snapshot entry, and orchestrator bootstrap. *)
let orchestrator_enabled_env_key = "MASC_ORCHESTRATOR_ENABLED"

(** SSOT for MASC_CONFIG_DIR / MASC_PERSONAS_DIR env-var names (issue 8352).
    Shared by snapshot catalog and docker worker inheritance list. *)
let config_dir_env_key = "MASC_CONFIG_DIR"
let personas_dir_env_key = "MASC_PERSONAS_DIR"

(* RFC-0085 PR-8 — [config_dir_opt] and [personas_dir_opt] removed.
   All readers now obtain these path values from
   [Host_config.from_env ()] (fields [config_dir] / [personas_dir]).
   The two [_env_key] string constants above remain because docker
   inheritance lists and snapshot catalogs still need them as
   identifier strings, not as readers. *)

(** SSOT for the MASC_DATA_DIR env-var name (issue 8352).
    Overrides [<base_path>/data] as the root for contract verdicts and other
    runtime data stores. Read by cdal_verdict_gate and cdal_eval_v1. *)
let data_dir_env_key = "MASC_DATA_DIR"

(** Data directory override. *)
let data_dir_opt () =
  raw_value_opt data_dir_env_key |> trim_opt

(** {1 Auth} *)

(** SSOT for auth env-var names (issue 8352). *)
let admin_token_env_key = "MASC_ADMIN_TOKEN"

(** Admin token for privileged endpoints. None = admin auth disabled. *)
let admin_token_opt () =
  raw_value_opt admin_token_env_key |> trim_opt

(** {1 Git operations} *)

(** [git fetch origin] is network-bound and can stall behind a slow
    Docker bridge or a large remote. Default 120s gives enough headroom
    for a cold fetch on a non-trivial repo while still bounding hung
    connections. Operators can override via [MASC_GIT_FETCH_TIMEOUT_SEC]
    when running on faster networks (e.g. 60s in CI) or slower ones
    (e.g. 300s on a constrained laptop tether). Floor 10s prevents a
    footgun setting like [0] from disabling the cap entirely. *)
let git_fetch_timeout_sec_env_key = "MASC_GIT_FETCH_TIMEOUT_SEC"

let git_fetch_timeout_sec () =
  Float.max 10.0
    (get_float ~default:120.0 git_fetch_timeout_sec_env_key)

(** {1 Logging / Telemetry} *)

(** SSOT for logging / observability env-var names (issue 8352). *)
let log_level_env_key = "MASC_LOG_LEVEL"
let log_routine_level_env_key = "MASC_LOG_ROUTINE_LEVEL"
let telemetry_enabled_env_key = "MASC_TELEMETRY_ENABLED"
(* [parse_warn_env_key] is defined near the top of this module (next to the
   malformed handler that consumes it). *)
let governance_level_env_key = "MASC_GOVERNANCE_LEVEL"

(** Log level string (e.g. "debug", "info", "warn", "error"). *)
let log_level_opt () =
  raw_value_opt log_level_env_key |> trim_opt

(** Whether telemetry tracking is enabled. Default: true. *)
let telemetry_enabled () =
  get_bool ~default:true telemetry_enabled_env_key

(** Whether malformed env parses are escalated to a hard [Config_error]
    (fail-fast boot) instead of a warn + default. Controlled by
    [MASC_PARSE_WARN]. Default: false (warn + use default). *)
let parse_warn_enabled () = parse_strict_mode ()

(** Governance level. Set at runtime by server_runtime_bootstrap.
    Valid: "production", "development", etc. Default: "production". *)
let governance_level () =
  get_string ~default:"production" governance_level_env_key
  |> String.lowercase_ascii

let disable_hitl_env_key = "MASC_DISABLE_HITL"

(** Whether to disable HITL (human-in-the-loop) approval gates. Default: false.
    @category Security
    @ops_class operator *)
let disable_hitl () =
  get_bool ~default:false disable_hitl_env_key

(** {1 Build Identity} *)

(** Git commit hash override for build identity. *)
let build_git_commit_opt () =
  raw_value_opt "MASC_BUILD_GIT_COMMIT" |> trim_opt

(** PubSub max messages per read. Default: 1000. *)
let pubsub_max_messages () =
  get_int ~default:1000 "MASC_PUBSUB_MAX_MESSAGES"

(** {1 Keeper Defaults} *)

(** Default sandbox profile for keepers. Default: "local".
    Set to "docker" to default all keepers to containerized execution. *)
let keeper_default_sandbox_profile_raw () =
  get_string ~default:"local" "MASC_KEEPER_DEFAULT_SANDBOX_PROFILE"

(** {1 Zombie Detection / Cleanup Configuration} *)
