(** Env-driven runtime configuration for {!Cascade_health_tracker}. *)

val window_sec : float
val cooldown_threshold : int
val cooldown_sec : float
val hard_quota_cooldown_sec : float
val terminal_failure_cooldown_sec : float
val soft_rate_limit_cooldown_sec : float
val soft_rate_limit_max_clamp_sec : float
val latency_ring_size : int
val confidence_ring_size : int
val cost_ring_size : int
val cooldown_config_for : provider_key:string -> int * float
