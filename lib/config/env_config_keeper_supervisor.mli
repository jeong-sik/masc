(** Keeper supervisor runtime configuration. *)

val domain_pool_enabled : bool
val max_restarts : int
val backoff_base_s : float
val backoff_max_s : float
val sweep_interval_sec : float
val self_preservation_ratio : float
val self_preservation_min_candidates : int
val dead_ttl_sec : float
val paused_cleanup_ttl_sec : float
val auto_resume_initial_sec : float
val auto_resume_max_sec : float
