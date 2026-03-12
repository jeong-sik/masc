(** MASC Environment Configuration

    Centralized environment variable management following 12-Factor App principles.
    All env vars use MASC_* prefix for consistency.
*)

include Env_config_core
include Env_config_runtime
include Env_config_governance
include Env_config_keeper

let print_summary () =
  Printf.eprintf "[env_config] Zombie: threshold=%.0fs cleanup_interval=%.0fs\n%!"
    Zombie.threshold_seconds Zombie.cleanup_interval_seconds;
  Printf.eprintf "[env_config] Lock: timeout=%.0fs expiry_warning=%.0fs\n%!"
    Lock.timeout_seconds Lock.expiry_warning_seconds;
  Printf.eprintf
    "[env_config] Session: max_age=%.0fs rate_limit_window=%.0fs\n%!"
    Session.max_age_seconds Session.rate_limit_window_seconds;
  Printf.eprintf
    "[env_config] Tempo: min=%.0fs max=%.0fs default=%.0fs\n%!"
    Tempo.min_interval_seconds Tempo.max_interval_seconds
    Tempo.default_interval_seconds;
  Printf.eprintf
    "[env_config] Llm: timeout=%.0fs cache_enabled=%b ttl=%ds max_prompt_chars=%d max_temp=%.2f l1_max=%d spawn_policy=%s\n%!"
    Llm.timeout_seconds Llm.cache_enabled Llm.cache_ttl_seconds
    Llm.cache_max_prompt_chars Llm.cache_max_temperature
    Llm.cache_l1_max_entries Llm.spawn_cache_policy;
  Printf.eprintf
    "[env_config] RateLimit: cleanup_interval=%.0fs entry_max_age=%.0fs\n%!"
    RateLimit.cleanup_interval_seconds RateLimit.entry_max_age_seconds;
  Printf.eprintf
    "[env_config] LodgeV2: tick=%.0fs agents_per_tick=%d planner=%b reflection_thresh=%d\n%!"
    LodgeV2.tick_interval_seconds LodgeV2.agents_per_tick LodgeV2.use_planner
    LodgeV2.reflection_threshold;
  Printf.eprintf
    "[env_config] LodgeSelection: max_starvation=%d thompson_weight=%.2f decay=%.2f\n%!"
    LodgeSelection.max_starvation_ticks LodgeSelection.thompson_weight
    LodgeSelection.vote_decay_factor;
  Printf.eprintf
    "[env_config] Gardener: enabled=%b min=%d target=%d max=%d spawns/day=%d\n%!"
    Gardener.enabled Gardener.min_agents Gardener.target_agents
    Gardener.max_agents Gardener.max_daily_spawns;
  Printf.eprintf
    "[env_config] KeeperBootstrap: enabled=%b stale_turn=%.0fs max_scan=%d\n%!"
    KeeperBootstrap.enabled KeeperBootstrap.stale_turn_seconds
    KeeperBootstrap.max_scan;
  Printf.eprintf
    "[env_config] KeeperAlert: enabled=%b min_score=%.2f retries=%d board=%b slack=%b github=%b\n%!"
    KeeperAlert.enabled KeeperAlert.min_score KeeperAlert.max_retries
    KeeperAlert.board_enabled KeeperAlert.slack_enabled KeeperAlert.github_enabled;
  Printf.eprintf
    "[env_config] KeeperAlert(SlackDM): enabled=%b user_id_set=%b\n%!"
    KeeperAlert.slack_dm_enabled
    (String.trim KeeperAlert.slack_dm_user_id <> "")
