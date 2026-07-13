(** MASC Environment Configuration

    Centralized environment variable management following 12-Factor App principles.
    All env vars use MASC_* prefix for consistency.
*)

include Env_config_core
include Env_config_runtime
include Env_config_runtime_services
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
    Env_config_runtime_services.Inference.timeout_seconds
    Env_config_runtime_services.Inference.cache_enabled
    Env_config_runtime_services.Inference.cache_ttl_seconds
    Env_config_runtime_services.Inference.cache_max_prompt_chars
    Env_config_runtime_services.Inference.cache_max_temperature
    Env_config_runtime_services.Inference.cache_l1_max_entries
    Env_config_runtime_services.Inference.spawn_cache_policy;
  Log.Env.info "RateLimit: cleanup_interval=%.0fs entry_max_age=%.0fs"
    Env_config_runtime_services.RateLimit.cleanup_interval_seconds
    Env_config_runtime_services.RateLimit.entry_max_age_seconds;
  Log.Env.info "Autonomy: quiet_hours=%d-%d"
    Env_config_runtime_services.Autonomy.quiet_start
    Env_config_runtime_services.Autonomy.quiet_end;
  Log.Env.info "AgentSelection: max_starvation=%d thompson_weight=%.2f decay=%.2f"
    Env_config_runtime_services.AgentSelection.max_starvation_ticks
    Env_config_runtime_services.AgentSelection.thompson_weight
    Env_config_runtime_services.AgentSelection.vote_decay_factor;
  Log.Env.info "KeeperBootstrap: enabled=%b stale_turn=%.0fs max_scan=%d"
    Env_config_keeper.KeeperBootstrap.enabled
    Env_config_keeper.KeeperBootstrap.stale_turn_seconds
    Env_config_keeper.KeeperBootstrap.max_scan;
  Log.Env.info "KeeperKeepalive: interval=%ds sleep_chunk=%.1fs"
    Env_config_keeper.KeeperKeepalive.interval_sec
    Env_config_keeper.KeeperKeepalive.sleep_chunk_sec;
  Log.Env.info "WorkAsHeartbeat: enabled=%b max_silence=%.0fs"
    Env_config_keeper.WorkAsHeartbeat.enabled
    Env_config_keeper.WorkAsHeartbeat.max_silence_sec;
  Log.Env.info "KeeperGrpc: reconnect_backoff=%.1fs"
    Env_config_keeper.KeeperGrpc.reconnect_backoff_sec;
  Log.Env.info "KeeperProactive: max_attempts=%d timing_ring=%d"
    Env_config_keeper.KeeperProactive.max_attempts
    Env_config_keeper.KeeperProactive.stage_timing_ring_size;
  Log.Env.info "KeeperSupervisor: dead_ttl=%.0fs"
    Env_config_keeper.KeeperSupervisor.dead_ttl_sec;
;;

(** Compatibility wrapper around the canonical config snapshot categories.
    Keep callers on [Env_config] while root-level wrappers may enrich the same
    read model with additional server metadata. *)
let to_json () : Yojson.Safe.t =
  Env_config_snapshot.to_json ()
