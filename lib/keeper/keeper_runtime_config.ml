(** Keeper_runtime_config — load startup keeper env seeding from
    [<resolved config root>/keeper_runtime.toml].  See [.mli] for design. *)

(* TOML key → env var name. Every keeper runtime knob maps here so
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
    "autonomous.max_turns_per_call",    "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS";
    "autonomous.semaphore_wait_timeout_sec", "MASC_KEEPER_SEMAPHORE_WAIT_TIMEOUT_SEC";
    "autonomous.concurrency",           "MASC_KEEPER_AUTONOMOUS_CONCURRENCY";
    "autonomous.slot_wait_timeout_sec", "MASC_KEEPER_AUTONOMOUS_SLOT_WAIT_TIMEOUT_SEC";
    "autonomous.fairness_cooldown_sec", "MASC_KEEPER_AUTONOMOUS_FAIRNESS_COOLDOWN_SEC";
    "autonomous.max_idle_turns",        "MASC_KEEPER_MAX_IDLE_TURNS_AUTONOMOUS";
    (* [reactive] *)
    "reactive.max_turns_per_call",      "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL";
    "reactive.concurrency",             "MASC_KEEPER_REACTIVE_CONCURRENCY";
    "reactive.max_idle_turns",          "MASC_KEEPER_MAX_IDLE_TURNS_REACTIVE";
    (* [heartbeat] *)
    "heartbeat.interval_sec",           "MASC_KEEPER_HEARTBEAT_INTERVAL_SEC";
    "heartbeat.max_silence_sec",        "MASC_KEEPER_MAX_SILENCE_SEC";
    "heartbeat.snapshot_sec",           "MASC_KEEPER_SNAPSHOT_SEC";
    "heartbeat.work_as_heartbeat",      "MASC_KEEPER_WORK_AS_HEARTBEAT";
    "heartbeat.smart_heartbeat",        "MASC_KEEPER_SMART_HEARTBEAT";
    "heartbeat.jitter_factor",          "MASC_KEEPER_HEARTBEAT_JITTER_FACTOR";
    "heartbeat.sleep_chunk_sec",        "MASC_KEEPER_SLEEP_CHUNK_SEC";
    "heartbeat.board_debounce_sec",     "MASC_KEEPER_BOARD_DEBOUNCE_SEC";
    "heartbeat.board_generic_wakeup_limit", "MASC_KEEPER_BOARD_GENERIC_WAKEUP_LIMIT";
    "heartbeat.board_wakeup_max",       "MASC_KEEPER_BOARD_WAKEUP_MAX";
    (* [proactive] *)
    "proactive.min_interval_sec",       "MASC_KEEPER_PROACTIVE_MIN_INTERVAL_SEC";
    (* [turn] *)
    "turn.timeout_sec",                 "MASC_KEEPER_TURN_TIMEOUT_SEC";
    "turn.oas_timeout_sec",             "MASC_KEEPER_OAS_TIMEOUT_SEC";
    "turn.stream_idle_timeout_sec",     "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC";
    "turn.cli_subprocess_idle_sec",     "MASC_KEEPER_CLI_SUBPROCESS_IDLE_SEC";
    "turn.admission_wait_timeout_sec",  "MASC_KEEPER_ADMISSION_WAIT_TIMEOUT_SEC";
    "turn.max_consecutive_hb_failures", "MASC_KEEPER_MAX_CONSECUTIVE_HB_FAILURES";
    "turn.max_consecutive_turn_failures", "MASC_KEEPER_MAX_CONSECUTIVE_TURN_FAILURES";
    "turn.batch_limit",                 "MASC_KEEPER_BATCH_LIMIT";
    "turn.tool_cost_max_usd",           "MASC_KEEPER_TOOL_COST_MAX_USD";
    "turn.max_tools_per_turn",          "MASC_KEEPER_MAX_TOOLS_PER_TURN";
    "turn.board_event_limit",           "MASC_KEEPER_BOARD_EVENT_LIMIT";
    "turn.llm_rerank",                  "MASC_KEEPER_LLM_RERANK";
    "turn.llm_rerank_cascade",          "MASC_KEEPER_LLM_RERANK_CASCADE";
    "turn.temperature",                 "MASC_KEEPER_UNIFIED_TEMP";
    "turn.max_output_tokens",           "MASC_KEEPER_UNIFIED_MAX_TOKENS";
    "turn.llama_slots",                 "MASC_KEEPER_LLAMA_SLOTS";
    "turn.enable_thinking",             "MASC_KEEPER_ENABLE_THINKING";
    "turn.adaptive_thinking",           "MASC_KEEPER_ADAPTIVE_THINKING";
    "turn.adaptive_thinking_mode",      "MASC_KEEPER_ADAPTIVE_THINKING_MODE";
    "turn.degraded_retry_slot_phase_budget_sec",
                                        "MASC_KEEPER_DEGRADED_RETRY_SLOT_PHASE_BUDGET_SEC";
    (* [watchdog] *)
    "watchdog.stale_sec",               "MASC_KEEPER_WATCHDOG_STALE_SEC";
    "watchdog.poll_sec",                "MASC_KEEPER_WATCHDOG_POLL_SEC";
    "watchdog.noop_threshold",          "MASC_KEEPER_WATCHDOG_NOOP_THRESHOLD";
    "watchdog.grace_sec",               "MASC_KEEPER_WATCHDOG_GRACE_SEC";
    (* [supervisor] *)
    "supervisor.max_restarts",          "MASC_KEEPER_SUPERVISOR_MAX_RESTARTS";
    "supervisor.backoff_base_sec",      "MASC_KEEPER_SUPERVISOR_BACKOFF_BASE_S";
    "supervisor.backoff_max_sec",       "MASC_KEEPER_SUPERVISOR_BACKOFF_MAX_S";
    "supervisor.sweep_sec",             "MASC_KEEPER_SUPERVISOR_SWEEP_SEC";
    "supervisor.alive_but_stuck_recovery_enabled",
                                        "MASC_KEEPER_ALIVE_BUT_STUCK_RECOVERY_ENABLED";
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
    (* [debug] *)
    "debug.enabled",                    "MASC_KEEPER_DEBUG";
  ]

let preempting_env_names env_name =
  match env_name with
  | "MASC_KEEPER_AUTOBOOT_MAX" ->
      [ "MASC_KEEPER_AUTOBOOT_MAX"; "MASC_KEEPER_AUTOBOT_MAX" ]
  | _ -> [ env_name ]

let env_is_set env_lookup env_name =
  preempting_env_names env_name
  |> List.exists (fun name -> Option.is_some (env_lookup name))

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
    Config_dir_resolver.keeper_runtime_toml_filename

let read_file path =
  try Ok (In_channel.with_open_text path In_channel.input_all)
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

(** Apply one TOML key to the corresponding env var, unless the env var
    is already set (caller override wins). Returns [true] iff a boot
    override was actually recorded.

    [~env_lookup] and [~env_set] are injectable for testing: production
    uses [Env_config_core.raw_value_opt] / [Config_boot_overrides.set];
    tests supply a fake env to avoid global process env dependence. *)
let apply_one
    ?(env_lookup = Env_config_core.raw_value_opt)
    ?(env_set = Config_boot_overrides.set)
    (doc : Keeper_toml_loader.toml_doc) (toml_key, env_name) =
  if env_is_set env_lookup env_name then
    (* Caller env override — leave alone. *)
    false
  else
    match List.assoc_opt toml_key doc with
    | None -> false
    | Some v ->
      match value_to_string v with
      | None -> false
      | Some s ->
        env_set env_name s;
        true

(** Pure version of the load+apply pipeline. Parses TOML and returns
    the number of overrides that would be applied, plus a list of
    (env_name, value) pairs. Exposed for testing without env side effects. *)
let resolve_overrides
    ?(env_lookup = Env_config_core.raw_value_opt)
    (doc : Keeper_toml_loader.toml_doc) =
  let applied = ref [] in
  let count =
    List.fold_left
      (fun acc (toml_key, env_name) ->
        if env_is_set env_lookup env_name then acc
        else
          match List.assoc_opt toml_key doc with
          | None -> acc
          | Some v ->
            match value_to_string v with
            | None -> acc
            | Some s ->
              applied := (env_name, s) :: !applied;
              acc + 1)
      0
      key_to_env
  in
  (count, List.rev !applied)

let load_and_apply ~base_path =
  let path = toml_path ~base_path in
  if not (Sys.file_exists path) then
    Ok 0
  else
    match read_file path with
    | Error msg -> Error (Printf.sprintf "read %s: %s" path msg)
    | Ok content ->
      match Keeper_toml_loader.parse_toml content with
      | Error msg -> Error (Printf.sprintf "parse %s: %s" path msg)
      | Ok doc ->
        let count =
          List.fold_left
            (fun acc kv -> if apply_one doc kv then acc + 1 else acc)
            0
            key_to_env
        in
        Ok count
