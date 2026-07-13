(** Keeper_runtime_config — load startup runtime env seeding from
    [<resolved config root>/runtime.toml].  See [.mli] for design. *)

(* TOML key → env var name. Startup-scoped runtime knobs map here so
   that TOML is the SSOT and env vars become CI/test overrides.
   Unknown TOML keys are silently ignored (forward compat). *)
let key_to_env =
  [
    (* [bootstrap] *)
    "bootstrap.enabled",                "MASC_KEEPER_BOOTSTRAP_ENABLED";
    "bootstrap.stale_turn_sec",         "MASC_KEEPER_BOOTSTRAP_STALE_TURN_SEC";
    "bootstrap.max_scan",               "MASC_KEEPER_BOOTSTRAP_MAX_SCAN";
    "bootstrap.autoboot_max",           "MASC_KEEPER_AUTOBOOT_MAX";
    (* [autonomous] *)
    (* RFC-0297 P0-1: global lifecycle kill-switches. Without these mappings
       the [reactive]/[proactive]/[autonomous] enabled keys were silently
       dropped (see load_and_apply — only known key_to_env keys are visited). *)
    "autonomous.enabled",               "MASC_KEEPER_AUTONOMOUS_ENABLED";
    "autonomous.fairness_cooldown_sec", "MASC_KEEPER_AUTONOMOUS_FAIRNESS_COOLDOWN_SEC";
    (* [reactive] *)
    "reactive.enabled",                 "MASC_KEEPER_REACTIVE_ENABLED";
    (* [heartbeat] *)
    "heartbeat.interval_sec",           "MASC_KEEPER_HEARTBEAT_INTERVAL_SEC";
    "heartbeat.max_silence_sec",        "MASC_KEEPER_MAX_SILENCE_SEC";
    "heartbeat.snapshot_sec",           "MASC_KEEPER_SNAPSHOT_SEC";
    "heartbeat.work_as_heartbeat",      "MASC_KEEPER_WORK_AS_HEARTBEAT";
    "heartbeat.sleep_chunk_sec",        "MASC_KEEPER_SLEEP_CHUNK_SEC";
    "heartbeat.board_wakeup_max",       "MASC_KEEPER_BOARD_WAKEUP_MAX";
    (* [health] *)
    "health.durable_queue_stale_sec",   "MASC_KEEPER_DURABLE_QUEUE_STALE_SEC";
    (* [wire_capture] *)
    "wire_capture.enabled",             "MASC_KEEPER_WIRE_CAPTURE";
    (* [proactive] *)
    "proactive.enabled",                "MASC_KEEPER_PROACTIVE_ENABLED";
    (* [turn] *)
    "turn.timeout_sec",                 "MASC_KEEPER_TURN_TIMEOUT_SEC";
    "turn.oas_timeout_sec",             "MASC_KEEPER_OAS_TIMEOUT_SEC";
    "turn.stream_idle_timeout_sec",     "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC";
    "turn.execution_idle_timeout_sec",  "MASC_KEEPER_EXECUTION_IDLE_TIMEOUT_SEC";
    "turn.cli_subprocess_idle_sec",     "MASC_KEEPER_CLI_SUBPROCESS_IDLE_SEC";
    "turn.capacity_limit",              "MASC_KEEPER_TURN_CAPACITY_LIMIT";
    "turn.batch_limit",                 "MASC_KEEPER_BATCH_LIMIT";
    "turn.temperature",                 "MASC_KEEPER_UNIFIED_TEMP";
    "turn.max_output_tokens",           "MASC_KEEPER_UNIFIED_MAX_TOKENS";
    "turn.enable_thinking",             "MASC_KEEPER_ENABLE_THINKING";
    (* [supervisor] *)
    "supervisor.sweep_sec",             "MASC_KEEPER_SUPERVISOR_SWEEP_SEC";
    (* [lifecycle] *)
    "lifecycle.dead_ttl_sec",           "MASC_KEEPER_DEAD_TTL_SEC";
    (* [budget] *)
    "budget.daily_usd",                 "MASC_KEEPER_DELIBERATION_DAILY_BUDGET_USD";
    (* [metrics] *)
    "metrics.max_bytes",                "MASC_KEEPER_METRICS_MAX_BYTES";
    "metrics.max_rotated",              "MASC_KEEPER_METRICS_MAX_ROTATED";
    (* [memory] *)
    "memory.max_notes",                 "MASC_KEEPER_MEMORY_MAX_NOTES";
    "memory.compact_trigger_bytes",     "MASC_KEEPER_MEMORY_COMPACT_TRIGGER_BYTES";
    "memory.max_length",                "MASC_KEEPER_MEMORY_MAX_LENGTH";
    "memory.placeholders",              "MASC_KEEPER_MEMORY_PLACEHOLDERS";
    "memory.consensus_pattern",         "MASC_KEEPER_MEMORY_CONSENSUS_PATTERN";
    "memory.llm_summary",               "MASC_KEEPER_MEMORY_LLM_SUMMARY";
    (* [web_search] *)
    "web_search.searxng_url",           "MASC_SEARXNG_URL";
    "web_search.provider",              "MASC_WEB_SEARCH_PROVIDER";
    "web_search.provider_order",        "MASC_WEB_SEARCH_PROVIDER_ORDER";
    "web_search.fallbacks",             "MASC_WEB_SEARCH_FALLBACKS";
    "web_search.timeout_sec",           "MASC_WEB_SEARCH_TIMEOUT_SEC";
    "web_search.cache_ttl_sec",         "MASC_WEB_SEARCH_CACHE_TTL_SEC";
    (* [debug] *)
    "debug.enabled",                    "MASC_KEEPER_DEBUG";
  ]

let env_is_set env_lookup env_name =
  Option.is_some (env_lookup env_name)

let resolved_config_root ~base_path =
  let inputs = Config_dir_resolver.inputs_from_env () in
  let resolution =
    Config_dir_resolver.resolve_with
      { inputs with env_base_path = Some base_path }
  in
  resolution.Config_dir_resolver.config_root.path

let toml_path ~base_path =
  Filename.concat
    (resolved_config_root ~base_path)
    Config_dir_resolver.runtime_toml_filename

let read_file path =
  (* Eio-native read (Fs_compat.load_file) so the keeper-runtime TOML
     read does not block the whole domain on each refresh. *)
  try Ok (Fs_compat.load_file path)
  with Sys_error msg -> Error msg

(** Format a TOML scalar back to a string suitable for the boot override store.
    Booleans → "true"/"false"; floats keep their TOML representation;
    strings pass through as-is. String arrays are not supported — they
    have no env var equivalent in the keeper config. *)
let value_to_string = function
  | Keeper_toml_loader.Toml_string s -> Some s
  | Keeper_toml_loader.Toml_int i -> Some (string_of_int i)
  | Keeper_toml_loader.Toml_float f ->
    (* Match TOML representation (no trailing zeros). *)
    Some (Printf.sprintf "%g" f)
  | Keeper_toml_loader.Toml_bool b -> Some (if b then "true" else "false")
  | Keeper_toml_loader.Toml_string_array _ -> None

(** Resolve a single TOML key to its boot-override value. Returns
    [Some (env_name, value)] when the key is present in the doc and the
    corresponding env var is unset (so the TOML value would apply).
    Returns [None] when the env var is already set (caller override wins)
    or the key is absent / unsupported.

    This is the single precedence rule shared by the pure preview
    ([resolve_overrides]) and the effectful apply path ([apply_one]):
    env var > TOML > hardcoded default. *)
let resolve_one
    ?(env_lookup = Env_config_core.raw_value_opt)
    (doc : Keeper_toml_loader.toml_doc) (toml_key, env_name) =
  if env_is_set env_lookup env_name then
    (* Caller env override — leave alone. *)
    None
  else
    match List.assoc_opt toml_key doc with
    | None -> None
    | Some v -> Option.map (fun s -> (env_name, s)) (value_to_string v)

(** Apply one TOML key to the corresponding env var, unless the env var
    is already set (caller override wins). Returns [true] iff a boot
    override was actually recorded.

    [~env_lookup] and [~env_set] are injectable for testing: production
    uses [Env_config_core.raw_value_opt] / [Config_boot_overrides.set];
    tests supply a fake env to avoid global process env dependence. *)
let apply_one
    ?(env_lookup = Env_config_core.raw_value_opt)
    ?(env_set = Config_boot_overrides.set)
    (doc : Keeper_toml_loader.toml_doc) pair =
  match resolve_one ~env_lookup doc pair with
  | None -> false
  | Some (env_name, s) ->
    env_set env_name s;
    true

(** Pure version of the load+apply pipeline. Parses TOML and returns
    the number of overrides that would be applied, plus a list of
    (env_name, value) pairs. Exposed for testing without env side effects. *)
let resolve_overrides
    ?(env_lookup = Env_config_core.raw_value_opt)
    (doc : Keeper_toml_loader.toml_doc) =
  let applied = List.filter_map (resolve_one ~env_lookup doc) key_to_env in
  (List.length applied, applied)

(* Shadow registry: stores every TOML value keyed by env name, even when
   the env var is already set.  This lets operator surfaces compare the
   effective env override against the operator's TOML intent (issue #17192). *)
let toml_shadow : (string, string) Hashtbl.t = Hashtbl.create 16

let toml_value_opt env_name = Hashtbl.find_opt toml_shadow env_name

let load_and_apply ~base_path =
  let path = toml_path ~base_path in
  if not (Sys.file_exists path) then
    Ok 0
  else
    match read_file path with
    | Error msg ->
      Error (Printf.sprintf "read %s: %s" path msg)
    | Ok content ->
      match Keeper_toml_loader.parse_toml content with
      | Error msg ->
        Error (Printf.sprintf "parse %s: %s" path msg)
      | Ok doc ->
        let count =
          List.fold_left
            (fun acc (toml_key, env_name) ->
               (* Populate shadow registry for every known key that has a
                  TOML value, regardless of whether env preempts it. *)
               (match List.assoc_opt toml_key doc with
                | None -> ()
                | Some v ->
                  match value_to_string v with
                  | None -> ()
                  | Some s -> Hashtbl.replace toml_shadow env_name s);
               if apply_one doc (toml_key, env_name) then acc + 1 else acc)
            0
            key_to_env
        in
        Ok count
