(** MASC Environment Configuration

    Centralized environment variable management following 12-Factor App principles.
    All env vars use MASC_* prefix for consistency.
*)

include Env_config_core
include Env_config_runtime
include Env_config_governance
include Env_config_keeper

let print_summary () =
  Log.Env.info "Zombie: threshold=%.0fs cleanup_interval=%.0fs"
    Env_config_runtime.Zombie.threshold_seconds
    Env_config_runtime.Zombie.cleanup_interval_seconds;
  Log.Env.warn "Lock: timeout=%.0fs expiry_warning=%.0fs"
    Env_config_runtime.Lock.timeout_seconds
    Env_config_runtime.Lock.expiry_warning_seconds;
  Log.Env.info "Session: max_age=%.0fs rate_limit_window=%.0fs"
    Env_config_runtime.Session.max_age_seconds
    Env_config_runtime.Session.rate_limit_window_seconds;
  Log.Env.info "Tempo: min=%.0fs max=%.0fs default=%.0fs"
    Env_config_runtime.Tempo.min_interval_seconds
    Env_config_runtime.Tempo.max_interval_seconds
    Env_config_runtime.Tempo.default_interval_seconds;
  Log.Env.info "Inference: timeout=%.0fs cache_enabled=%b ttl=%ds max_prompt_chars=%d max_temp=%.2f l1_max=%d spawn_policy=%s"
    Env_config_governance.Inference.timeout_seconds
    Env_config_governance.Inference.cache_enabled
    Env_config_governance.Inference.cache_ttl_seconds
    Env_config_governance.Inference.cache_max_prompt_chars
    Env_config_governance.Inference.cache_max_temperature
    Env_config_governance.Inference.cache_l1_max_entries
    Env_config_governance.Inference.spawn_cache_policy;
  Log.Env.info "RateLimit: cleanup_interval=%.0fs entry_max_age=%.0fs"
    Env_config_governance.RateLimit.cleanup_interval_seconds
    Env_config_governance.RateLimit.entry_max_age_seconds;
  Log.Env.info "Autonomy: quiet_hours=%d-%d"
    Env_config_governance.Autonomy.quiet_start
    Env_config_governance.Autonomy.quiet_end;
  Log.Env.info "AgentSelection: max_starvation=%d thompson_weight=%.2f decay=%.2f"
    Env_config_governance.AgentSelection.max_starvation_ticks
    Env_config_governance.AgentSelection.thompson_weight
    Env_config_governance.AgentSelection.vote_decay_factor;
  Log.Env.info "KeeperBootstrap: enabled=%b stale_turn=%.0fs max_scan=%d"
    Env_config_keeper.KeeperBootstrap.enabled
    Env_config_keeper.KeeperBootstrap.stale_turn_seconds
    Env_config_keeper.KeeperBootstrap.max_scan;
  Log.Env.info "KeeperAlert: enabled=%b min_score=%.2f retries=%d board=%b slack=%b github=%b"
    Env_config_keeper.KeeperAlert.enabled
    Env_config_keeper.KeeperAlert.min_score
    Env_config_keeper.KeeperAlert.max_retries
    Env_config_keeper.KeeperAlert.board_enabled
    Env_config_keeper.KeeperAlert.slack_enabled
    Env_config_keeper.KeeperAlert.github_enabled;
  Log.Env.info "KeeperAlert(SlackDM): enabled=%b user_id_set=%b"
    Env_config_keeper.KeeperAlert.slack_dm_enabled
    (String.trim Env_config_keeper.KeeperAlert.slack_dm_user_id <> "");
  Log.Env.info "KeeperKeepalive: interval=%ds max_hb_failures=%d debounce=%.0fs sleep_chunk=%.1fs jitter=%.2f"
    Env_config_keeper.KeeperKeepalive.interval_sec
    Env_config_keeper.KeeperKeepalive.max_consecutive_failures
    Env_config_keeper.KeeperKeepalive.board_debounce_sec
    Env_config_keeper.KeeperKeepalive.sleep_chunk_sec
    Env_config_keeper.KeeperKeepalive.jitter_factor;
  Log.Env.info "WorkAsHeartbeat: enabled=%b max_silence=%.0fs"
    Env_config_keeper.WorkAsHeartbeat.enabled
    Env_config_keeper.WorkAsHeartbeat.max_silence_sec;
  Log.Env.info "SmartHeartbeat: enabled=%b"
    Env_config_keeper.SmartHeartbeat.enabled;
  Log.Env.info "KeeperGrpc: max_reconnect=%d backoff=%.1fs"
    Env_config_keeper.KeeperGrpc.max_reconnect_attempts
    Env_config_keeper.KeeperGrpc.reconnect_backoff_sec;
  Log.Env.info "KeeperProactive: max_attempts=%d timing_ring=%d"
    Env_config_keeper.KeeperProactive.max_attempts
    Env_config_keeper.KeeperProactive.stage_timing_ring_size;
  Log.Env.info "SelfPreservation: ratio=%.2f min_candidates=%d dead_ttl=%.0fs"
    Env_config_keeper.KeeperSupervisor.self_preservation_ratio
    Env_config_keeper.KeeperSupervisor.self_preservation_min_candidates
    Env_config_keeper.KeeperSupervisor.dead_ttl_sec

(** Serialize all known configuration as JSON for dashboard introspection.
    Sensitive values (passwords, tokens, API keys) are masked. *)
let to_json () : Yojson.Safe.t =
  let mask s =
    if String.length s <= 4 then "***"
    else String.sub s 0 (min 4 (String.length s)) ^ "***"
  in
  let mask_opt f = match f () with Some v -> `String (mask v) | None -> `Null in
  let str s = `String s in
  let str_opt f = match f () with Some v -> `String v | None -> `Null in
  let int_val i = `Int i in
  let float_val f = `Float f in
  let bool_val b = `Bool b in
  `Assoc [
    "core", `Assoc [
      "me_root", str_opt me_root_opt;
      "sb_path", str_opt sb_path_opt;
      "http_port", str (masc_http_port ());
      "host", str (masc_host ());
      "http_base_url", (match masc_http_base_url_result () with Ok u -> str u | Error _ -> `Null);
      "assets_dir", str_opt assets_dir_opt;
      "cluster_name", str (cluster_name ());
    ];
    "runtime", `Assoc [
      "zombie_threshold_sec", float_val Env_config_runtime.Zombie.threshold_seconds;
      "zombie_keeper_threshold_sec", float_val Env_config_runtime.Zombie.keeper_threshold_seconds;
      "zombie_cleanup_interval_sec", float_val Env_config_runtime.Zombie.cleanup_interval_seconds;
      "lock_timeout_sec", float_val Env_config_runtime.Lock.timeout_seconds;
      "session_max_age_sec", float_val Env_config_runtime.Session.max_age_seconds;
      "tempo_min_sec", float_val Env_config_runtime.Tempo.min_interval_seconds;
      "tempo_max_sec", float_val Env_config_runtime.Tempo.max_interval_seconds;
      "tempo_default_sec", float_val Env_config_runtime.Tempo.default_interval_seconds;
    ];
    "governance", `Assoc [
      "inference_timeout_sec", float_val Env_config_governance.Inference.timeout_seconds;
      "inference_cache_enabled", bool_val Env_config_governance.Inference.cache_enabled;
      "inference_cache_ttl_sec", int_val Env_config_governance.Inference.cache_ttl_seconds;
      "autonomy_quiet_start", int_val Env_config_governance.Autonomy.quiet_start;
      "autonomy_quiet_end", int_val Env_config_governance.Autonomy.quiet_end;
    ];
    "keeper", `Assoc [
      "bootstrap_enabled", bool_val Env_config_keeper.KeeperBootstrap.enabled;
      "bootstrap_stale_turn_sec", float_val Env_config_keeper.KeeperBootstrap.stale_turn_seconds;
      "bootstrap_max_scan", int_val Env_config_keeper.KeeperBootstrap.max_scan;
      "alert_enabled", bool_val Env_config_keeper.KeeperAlert.enabled;
      "alert_min_score", float_val Env_config_keeper.KeeperAlert.min_score;
      "alert_slack_enabled", bool_val Env_config_keeper.KeeperAlert.slack_enabled;
      "keepalive_interval_sec", int_val Env_config_keeper.KeeperKeepalive.interval_sec;
      "keepalive_max_hb_failures", int_val Env_config_keeper.KeeperKeepalive.max_consecutive_failures;
      "keepalive_board_debounce_sec", float_val Env_config_keeper.KeeperKeepalive.board_debounce_sec;
      "keepalive_sleep_chunk_sec", float_val Env_config_keeper.KeeperKeepalive.sleep_chunk_sec;
      "keepalive_jitter_factor", float_val Env_config_keeper.KeeperKeepalive.jitter_factor;
      "grpc_max_reconnect", int_val Env_config_keeper.KeeperGrpc.max_reconnect_attempts;
      "grpc_reconnect_backoff_sec", float_val Env_config_keeper.KeeperGrpc.reconnect_backoff_sec;
      "proactive_max_attempts", int_val Env_config_keeper.KeeperProactive.max_attempts;
      "stage_timing_ring_size", int_val Env_config_keeper.KeeperProactive.stage_timing_ring_size;
      "work_as_heartbeat_enabled", bool_val Env_config_keeper.WorkAsHeartbeat.enabled;
      "work_as_heartbeat_max_silence_sec", float_val Env_config_keeper.WorkAsHeartbeat.max_silence_sec;
      "smart_heartbeat_enabled", bool_val Env_config_keeper.SmartHeartbeat.enabled;
      "self_preservation_ratio", float_val Env_config_keeper.KeeperSupervisor.self_preservation_ratio;
      "self_preservation_min_candidates", int_val Env_config_keeper.KeeperSupervisor.self_preservation_min_candidates;
      "dead_ttl_sec", float_val Env_config_keeper.KeeperSupervisor.dead_ttl_sec;
    ];
    "server", `Assoc [
      "grpc_enabled", bool_val (Env_config_runtime.Transport.grpc_enabled ());
      "grpc_port", int_val Env_config_runtime.Transport.grpc_port;
      "ws_enabled", bool_val (Env_config_runtime.Transport.ws_enabled ());
      "ws_port", int_val Env_config_runtime.Transport.ws_port;
      "h2_mode", str (Env_config_runtime.Transport.use_h2 ());
      "webrtc_enabled", bool_val (Env_config_runtime.Transport.webrtc_enabled ());
      "storage_type", str (Env_config_core.storage_type ());
      "pg_pool_size", int_val (Env_config_core.pg_pool_size ());
      "telemetry_enabled", bool_val (Env_config_core.telemetry_enabled ());
      "openai_compat", bool_val Env_config_runtime.Transport.openai_compat_enabled;
      "dispatch_v2", bool_val Env_config_runtime.Tools.dispatch_v2_enabled;
      "rate_limit", float_val Env_config_runtime.Rate_bucket.rate;
      "rate_burst", int_val Env_config_runtime.Rate_bucket.burst;
      "build_git_commit", str_opt build_git_commit_opt;
    ];
    "model_defaults", `Assoc [
      "default_cascade", str_opt Env_config_governance.Model_defaults.default_cascade_opt;
      "default_provider", str_opt Env_config_governance.Model_defaults.default_provider_opt;
      "default_model", str_opt Env_config_governance.Model_defaults.default_model_opt;
      "llama_swarm_model", str_opt Env_config_runtime.Local_runtime.llama_swarm_model_opt;
    ];
    "dashboard", `Assoc [
      "fixtures_enabled", bool_val (Env_config_governance.Dashboard_config.fixtures_enabled ());
      "governance_judge_enabled", bool_val Env_config_governance.Dashboard_config.governance_judge_enabled;
      "governance_judge_interval_sec", int_val Env_config_governance.Dashboard_config.governance_judge_interval_sec;
      "operator_judge_enabled", bool_val Env_config_governance.Operator.judge_enabled;
      "operator_judge_interval_sec", int_val Env_config_governance.Operator.judge_interval_sec;
      "relay_calibration_enabled", bool_val (get_bool ~default:true "MASC_RELAY_CALIBRATION_ENABLED");
    ];
    "external", `Assoc [
      "graphql_url", str (match Sys.getenv_opt "GRAPHQL_URL" with Some u -> u | None -> "");
      "neo4j_uri", mask_opt (fun () -> Sys.getenv_opt "NEO4J_URI");
      "neo4j_password", mask_opt (fun () -> Sys.getenv_opt "NEO4J_PASSWORD");
      "gemini_api_key", mask_opt (fun () -> Sys.getenv_opt "GEMINI_API_KEY");
      "graphql_api_key", mask_opt (fun () -> Sys.getenv_opt "GRAPHQL_API_KEY");
    ];
  ]
