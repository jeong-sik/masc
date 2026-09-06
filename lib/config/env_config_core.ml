(** MASC Environment Configuration

    Centralized environment variable management following 12-Factor App principles.
    All env vars use MASC_* prefix for consistency.

    Functions ending in [_result] return [(string, string) result] and are
    the preferred API.  Convenience functions without [_result] suffix raise
    {!Config_error} on missing/invalid environment variables.

    Usage:
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

(* One reading of a MASC_*_RETENTION_DAYS knob, because the value decides
   whether files are deleted and the stores disagreed about a malformed one.
   tool_usage_log and keeper_runtime_manifest_housekeeping kept files forever;
   keeper_tool_call_log started pruning at its 30-day default. Both cited the
   third in a comment as the model they followed. A single operator typo —
   3O for 30 — therefore deleted from one store and stopped deleting from
   another, silently (#27110).

   Malformed now means the same thing everywhere: the store's declared
   default, with the WARN [reject_malformed_env] already emits. An explicit
   zero or negative is the one way to say "keep everything", and it means that
   in every store. *)
type retention =
  | Retain_forever
  | Prune_after_days of int

let get_retention_days ~default name =
  match raw_value_opt name with
  | None -> default
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = ""
    then default
    else (
      match Safe_ops.int_of_string_safe trimmed with
      | Some days when days > 0 -> Prune_after_days days
      | Some _ -> Retain_forever
      | None ->
        reject_malformed_env ~name ~raw ~type_name:"retention days (integer)";
        default)
;;

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
    value (e.g. [MASC_KEEPER_METRICS_MAX_BYTES=-5]) gets the default
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
(* Canonical clamped read (RFC-0371 B7): before this, four modules each
   carried their own [int_of_env_default] with a raw getenv + parse +
   clamp body — the same helper, re-derived, drifting. *)
let get_int_clamped ~default ~min_v ~max_v name =
  let v = get_int ~default name in
  max min_v (min max_v v)

let get_float_clamped ~default ~min_v ~max_v name =
  let v = get_float ~default name in
  Float.max min_v (Float.min max_v v)

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

let bool_of_raw_value raw =
  match String.trim raw |> String.lowercase_ascii with
  | "true" | "1" | "yes" | "on" -> Some true
  | "false" | "0" | "no" | "off" -> Some false
  | _ -> None

let get_bool ~default name =
  match raw_value_opt name with
  | None -> default
  | Some raw ->
      if String.trim raw = "" then default
      else (
        match bool_of_raw_value raw with
        | Some value -> value
        | None ->
            reject_malformed_env ~name ~raw ~type_name:"bool";
            default)

let get_bool_strict ~default name =
  match raw_value_opt name with
  | None -> default
  | Some raw ->
      if String.trim raw = "" then default
      else (
        match bool_of_raw_value raw with
        | Some value -> value
        | None ->
            raise
              (Config_error
                 (Printf.sprintf "malformed env %s=%S (expected bool)" name raw)))

let trim_opt = function
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed
  | None -> None

let strip_trailing_slashes = Masc_network_defaults.trim_trailing_slashes

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
  match masc_http_base_url_opt () with
  | Some base -> Ok base
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

and masc_http_base_url_opt () =
  raw_value_opt http_base_url_env_key
  |> trim_opt
  |> Option.map strip_trailing_slashes

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
let host_fd_pressure_poller_disabled_env_key = "MASC_HOST_FD_PRESSURE_POLLER_DISABLED"
let host_fd_pressure_poll_interval_sec_env_key = "MASC_HOST_FD_PRESSURE_POLL_INTERVAL_SEC"

let host_fd_pressure_state_file_path_opt () =
  raw_value_opt host_fd_pressure_state_file_env_key |> trim_opt

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
    Used by board, checkpoint, voice, keeper.
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

(* Keeper sandbox test hooks, same shape as the guard above.

   [keeper_sandbox_runtime_setup.ml] read MASC_TEST_FAKE_DOCKER_PATH at three
   call sites, each spelling the "set and non-blank" test its own way, and
   MASC_TEST_ALLOW_REAL_DOCKER at a fourth. Reading them here gives the two
   keys one reader and routes them through [raw_value_opt], so a boot override
   reaches them like every other key -- a direct [Sys.getenv_opt] did not. *)
let test_fake_docker_path_env = "MASC_TEST_FAKE_DOCKER_PATH"
let test_allow_real_docker_env = "MASC_TEST_ALLOW_REAL_DOCKER"

let fake_docker_path_opt () =
  raw_value_opt test_fake_docker_path_env |> trim_opt

let real_docker_allowed_under_test () =
  match raw_value_opt test_allow_real_docker_env |> trim_opt with
  | Some v -> String.equal v "1" || String.equal v "true"
  | None -> false

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

(** Resolve a configured path against the project base path. Relative
    paths are concatenated onto [base_path ()]; absolute paths are
    returned unchanged. *)
let resolve_against_base_path raw_path =
  if Filename.is_relative raw_path then
    Filename.concat (base_path ()) raw_path
  else
    raw_path

(** SSOT for the MASC_ORCHESTRATOR_ENABLED env-var name (issue 8352).
    Referenced by feature_flag_registry catalog, env_config_runtime reader,
    env_config_snapshot entry, and orchestrator bootstrap. *)
let orchestrator_enabled_env_key = "MASC_ORCHESTRATOR_ENABLED"

(** SSOT for the MASC_CONFIG_DIR env-var name (issue 8352). *)
let config_dir_env_key = "MASC_CONFIG_DIR"

(** SSOT for the MASC_DATA_DIR env-var name (issue 8352).
    Overrides [<base_path>/data] as the root for runtime data stores. *)
let data_dir_env_key = "MASC_DATA_DIR"

(** Data directory override. *)
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

(** Log level string (e.g. "debug", "info", "warn", "error"). *)
(** Whether telemetry tracking is enabled. Default: true. *)
let telemetry_enabled () =
  get_bool ~default:true telemetry_enabled_env_key

(** Whether malformed env parses are escalated to a hard [Config_error]
    (fail-fast boot) instead of a warn + default. Controlled by
    [MASC_PARSE_WARN]. Default: false (warn + use default). *)
(** PubSub max messages per read. Default: 1000. *)
let pubsub_max_messages () =
  get_int ~default:1000 "MASC_PUBSUB_MAX_MESSAGES"

(** Day-file retention for the JSONL stores under [.masc]. Default: 30.

    Read by the startup prune and the periodic maintenance prune. Both decide
    which day files are deleted; a default that differed between them would
    let one prune delete files the other still expects to keep.

    @category Policies @ops_class operator *)
let default_jsonl_retention_days = 30

let jsonl_retention_days_env_key = "MASC_JSONL_RETENTION_DAYS"

let jsonl_retention_days () =
  get_int ~default:default_jsonl_retention_days jsonl_retention_days_env_key

(** {1 Keeper Defaults} *)
