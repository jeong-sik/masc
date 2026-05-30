(** Env-driven runtime configuration for {!Cascade_health_tracker}. *)

val window_sec : float
val cooldown_threshold : int
val cooldown_sec : float
val hard_quota_cooldown_sec : float
val terminal_failure_cooldown_sec : float
val soft_rate_limit_cooldown_sec : float
val soft_rate_limit_max_clamp_sec : float
val default_capacity_backpressure_backoff_sec : float
(** Synthetic backoff applied when a [Capacity_backpressure] error arrives
    without an explicit [retry_after_sec] hint.  Sized below
    {!soft_rate_limit_cooldown_sec} (10s) — capacity backpressure is a
    short-window signal that a different provider is probably ready
    sooner — but above zero so the cascade does not immediately rotate
    onto the same degraded provider.  Tunable via
    [MASC_CASCADE_CAPACITY_BACKPRESSURE_DEFAULT_BACKOFF_SEC]. *)
val latency_ring_size : int
val confidence_ring_size : int
val cost_ring_size : int
val cooldown_config_for : provider_key:string -> int * float
