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
  Log.Env.info "LodgeV2: tick=%.0fs agents_per_tick=%d planner=%b reflection_thresh=%d"
    Env_config_governance.LodgeV2.tick_interval_seconds
    Env_config_governance.LodgeV2.agents_per_tick
    Env_config_governance.LodgeV2.use_planner
    Env_config_governance.LodgeV2.reflection_threshold;
  Log.Env.info "SocialRuntime: enabled=%b strategy=%s"
    Env_config_governance.SocialRuntime.enabled
    (Env_config_governance.SocialRuntime.strategy
     |> Env_config_governance.SocialRuntime.strategy_to_string);
  Log.Env.info "LodgeSelection: max_starvation=%d thompson_weight=%.2f decay=%.2f"
    Env_config_governance.LodgeSelection.max_starvation_ticks
    Env_config_governance.LodgeSelection.thompson_weight
    Env_config_governance.LodgeSelection.vote_decay_factor;
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
    (String.trim Env_config_keeper.KeeperAlert.slack_dm_user_id <> "")
