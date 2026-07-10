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
    "bootstrap.max_active_keepers",     "MASC_KEEPER_BOOTSTRAP_MAX_ACTIVE_KEEPERS";
    "bootstrap.autoboot_max",           "MASC_KEEPER_AUTOBOOT_MAX";
    (* [autonomous] *)
    (* RFC-0297 P0-1: global lifecycle kill-switches. Without these mappings
       the [reactive]/[proactive]/[autonomous] enabled keys were silently
       dropped (see load_and_apply — only known key_to_env keys are visited). *)
    "autonomous.enabled",               "MASC_KEEPER_AUTONOMOUS_ENABLED";
    "autonomous.fairness_cooldown_sec", "MASC_KEEPER_AUTONOMOUS_FAIRNESS_COOLDOWN_SEC";
    "autonomous.max_idle_turns",        "MASC_KEEPER_MAX_IDLE_TURNS_AUTONOMOUS";
    (* [reactive] *)
    "reactive.enabled",                 "MASC_KEEPER_REACTIVE_ENABLED";
    "reactive.max_idle_turns",          "MASC_KEEPER_MAX_IDLE_TURNS_REACTIVE";
    (* [heartbeat] *)
    "heartbeat.interval_sec",           "MASC_KEEPER_HEARTBEAT_INTERVAL_SEC";
    "heartbeat.max_silence_sec",        "MASC_KEEPER_MAX_SILENCE_SEC";
    "heartbeat.snapshot_sec",           "MASC_KEEPER_SNAPSHOT_SEC";
    "heartbeat.work_as_heartbeat",      "MASC_KEEPER_WORK_AS_HEARTBEAT";
    "heartbeat.smart_heartbeat",        "MASC_KEEPER_SMART_HEARTBEAT";
    "heartbeat.jitter_factor",          "MASC_KEEPER_HEARTBEAT_JITTER_FACTOR";
    "heartbeat.sleep_chunk_sec",        "MASC_KEEPER_SLEEP_CHUNK_SEC";
    "heartbeat.board_wakeup_max",       "MASC_KEEPER_BOARD_WAKEUP_MAX";
    (* [health] *)
    "health.durable_queue_stale_sec",   "MASC_KEEPER_DURABLE_QUEUE_STALE_SEC";
    (* [wire_capture] *)
    "wire_capture.enabled",             "MASC_KEEPER_WIRE_CAPTURE";
    (* [proactive] *)
    "proactive.enabled",                "MASC_KEEPER_PROACTIVE_ENABLED";
    "proactive.min_interval_sec",       "MASC_KEEPER_PROACTIVE_MIN_INTERVAL_SEC";
    "proactive.noop_backoff_max_shift", "MASC_KEEPER_PROACTIVE_NOOP_BACKOFF_MAX_SHIFT";
    "proactive.idle_decay_max_periods", "MASC_KEEPER_PROACTIVE_IDLE_DECAY_MAX_PERIODS";
    (* [turn] *)
    "turn.timeout_sec",                 "MASC_KEEPER_TURN_TIMEOUT_SEC";
    "turn.oas_timeout_sec",             "MASC_KEEPER_OAS_TIMEOUT_SEC";
    "turn.admission_wait_timeout_sec",  "MASC_KEEPER_ADMISSION_WAIT_TIMEOUT_SEC";
    "turn.idle_skip_threshold",         "MASC_KEEPER_IDLE_SKIP_THRESHOLD";
    "turn.stream_idle_timeout_sec",     "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC";
    "turn.execution_idle_timeout_sec",  "MASC_KEEPER_EXECUTION_IDLE_TIMEOUT_SEC";
    "turn.cli_subprocess_idle_sec",     "MASC_KEEPER_CLI_SUBPROCESS_IDLE_SEC";
    "turn.capacity_limit",              "MASC_KEEPER_TURN_CAPACITY_LIMIT";
    "turn.max_consecutive_hb_failures", "MASC_KEEPER_MAX_CONSECUTIVE_HB_FAILURES";
    "turn.max_consecutive_turn_failures", "MASC_KEEPER_MAX_CONSECUTIVE_TURN_FAILURES";
    "turn.chat_waiting_cap",          "MASC_KEEPER_TURN_CHAT_WAITING_CAP";
    "turn.batch_limit",                 "MASC_KEEPER_BATCH_LIMIT";
    "turn.llm_rerank",                  "MASC_KEEPER_LLM_RERANK";
    "turn.llm_rerank_runtime",          "MASC_KEEPER_LLM_RERANK_RUNTIME";
    "turn.temperature",                 "MASC_KEEPER_UNIFIED_TEMP";
    "turn.max_output_tokens",           "MASC_KEEPER_UNIFIED_MAX_TOKENS";
    "turn.enable_thinking",             "MASC_KEEPER_ENABLE_THINKING";
    "turn.adaptive_thinking",           "MASC_KEEPER_ADAPTIVE_THINKING";
    "turn.degraded_retry_slot_phase_budget_sec",
                                        "MASC_KEEPER_DEGRADED_RETRY_SLOT_PHASE_BUDGET_SEC";
    (* [supervisor] *)
    "supervisor.max_restarts",          "MASC_KEEPER_SUPERVISOR_MAX_RESTARTS";
    "supervisor.backoff_base_sec",      "MASC_KEEPER_SUPERVISOR_BACKOFF_BASE_S";
    "supervisor.backoff_max_sec",       "MASC_KEEPER_SUPERVISOR_BACKOFF_MAX_S";
    "supervisor.sweep_sec",             "MASC_KEEPER_SUPERVISOR_SWEEP_SEC";
    (* [lifecycle] *)
    "lifecycle.self_preservation_ratio","MASC_KEEPER_SELF_PRESERVATION_RATIO";
    "lifecycle.self_preservation_min",  "MASC_KEEPER_SELF_PRESERVATION_MIN_CANDIDATES";
    "lifecycle.dead_ttl_sec",           "MASC_KEEPER_DEAD_TTL_SEC";
    "lifecycle.paused_cleanup_ttl_sec", "MASC_KEEPER_PAUSED_CLEANUP_TTL_SEC";
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
    (* [alert] *)
    "alert.enabled",                    "MASC_KEEPER_ALERT_ENABLED";
    "alert.min_score",                  "MASC_KEEPER_ALERT_MIN_SCORE";
    "alert.max_body_chars",             "MASC_KEEPER_ALERT_MAX_BODY_CHARS";
    "alert.max_retries",                "MASC_KEEPER_ALERT_MAX_RETRIES";
    "alert.retry_base_delay_ms",        "MASC_KEEPER_ALERT_RETRY_BASE_DELAY_MS";
    "alert.board_enabled",              "MASC_KEEPER_ALERT_BOARD_ENABLED";
    "alert.board_author",               "MASC_KEEPER_ALERT_BOARD_AUTHOR";
    "alert.board_hearth",               "MASC_KEEPER_ALERT_BOARD_HEARTH";
    "alert.board_visibility",           "MASC_KEEPER_ALERT_BOARD_VISIBILITY";
    "alert.slack_enabled",              "MASC_KEEPER_ALERT_SLACK_ENABLED";
    "alert.slack_webhook_url",          "MASC_KEEPER_ALERT_SLACK_WEBHOOK_URL";
    "alert.slack_dm_enabled",           "MASC_KEEPER_ALERT_SLACK_DM_ENABLED";
    "alert.slack_dm_user_id",           "MASC_KEEPER_ALERT_SLACK_DM_USER_ID";
    "alert.github_enabled",             "MASC_KEEPER_ALERT_GITHUB_ENABLED";
    "alert.github_repo",                "MASC_KEEPER_ALERT_GITHUB_REPO";
    "alert.github_label",               "MASC_KEEPER_ALERT_GITHUB_LABEL";
    "alert.github_min_score",           "MASC_KEEPER_ALERT_GITHUB_MIN_SCORE";
    (* [web_search] *)
    "web_search.searxng_url",           "MASC_SEARXNG_URL";
    "web_search.provider",              "MASC_WEB_SEARCH_PROVIDER";
    "web_search.provider_order",        "MASC_WEB_SEARCH_PROVIDER_ORDER";
    "web_search.fallbacks",             "MASC_WEB_SEARCH_FALLBACKS";
    "web_search.timeout_sec",           "MASC_WEB_SEARCH_TIMEOUT_SEC";
    "web_search.cache_ttl_sec",         "MASC_WEB_SEARCH_CACHE_TTL_SEC";
    "web_search.rate_limit_window_sec", "MASC_WEB_SEARCH_RATE_LIMIT_WINDOW_SEC";
    "web_search.rate_limit_max_calls",  "MASC_WEB_SEARCH_RATE_LIMIT_MAX_CALLS";
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
