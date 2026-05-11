(** Env_config_keeper — keeper runtime parameters from environment.

    All [MASC_KEEPER_*] env vars in this module can also be set
    declaratively in [<resolved config root>/keeper_runtime.toml].
    Precedence: process env > TOML > hardcoded default.

    Surface flows through [include Env_config_keeper] in
    {!Env_config}, so callers reach values either as
    [Env_config.<Module>.<field>] or as [Env_config.<top_level>] for
    the few unscoped lets at this boundary. *)

(** {1 Keeper bootstrap} *)

module KeeperBootstrap : sig
  val enabled : bool
  val stale_turn_seconds : float
  val max_scan : int
  val max_active_keepers : int
  val lazy_startup_poll_interval_sec : float
  val keeper_listener_retry_interval_sec : float
  val post_startup_settle_sec : float
end

(** {1 Keeper metrics rotation} *)

module KeeperMetrics : sig
  val max_file_bytes : int
  val max_rotated_files : int
end

(** {1 Keeper interesting-alert fanout} *)

module KeeperAlert : sig
  val enabled : bool
  val min_score : float
  val max_body_chars : int
  val max_retries : int
  val retry_base_delay_ms : int
  val board_enabled : bool
  val board_author : string
  val board_hearth : string
  val board_visibility : string
  val slack_enabled : bool
  val slack_webhook_url : string
  val slack_dm_enabled : bool
  val slack_dm_user_id : string
  val github_enabled : bool
  val github_repo : string
  val github_label : string
  val github_min_score : float
end

(** {1 Keeper supervisor} *)

module KeeperSupervisor : sig
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

  (** #12801 Whether the liveness recovery scan is enabled. *)
  val liveness_recovery_enabled : bool

  (** Minimum seconds a keeper must have been Dead before recovery attempt. *)
  val liveness_recovery_min_dead_sec : float

  (** Base backoff delay between liveness recovery attempts (seconds). *)
  val liveness_recovery_backoff_base_sec : float

  (** Maximum backoff delay cap for liveness recovery (seconds). *)
  val liveness_recovery_backoff_max_sec : float

  (** Maximum total liveness recovery attempts per keeper. *)
  val liveness_recovery_max_attempts : int

  (** #12838 Scan for alive-but-stuck keepers
      (proactive_rt.last_ts frozen while autonomous turns advance).
      Default: true. *)
  val alive_but_stuck_enabled : bool

  (** Queue a bounded Event Layer wakeup for each deduped
      alive-but-stuck detection. Default: true. *)
  val alive_but_stuck_recovery_enabled : bool

  (** Multiplier on the keeper's [proactive.cooldown_sec] before
      stalling is flagged. Default: 10. *)
  val alive_but_stuck_stall_multiplier : int

  (** Hard floor (seconds) for stall detection — guards against
      keepers with very small cooldowns being flagged after a few
      minutes of legitimate quiet. Default: 1800 (30 min). *)
  val alive_but_stuck_stall_floor_sec : float

  (** Per-keeper dedup window: counter increments at most once per
      window per keeper even when the sweep fires every 30s.
      Default: 3600 (1 hr). *)
  val alive_but_stuck_dedup_ttl_sec : float
end

(** {1 Stale-turn watchdog} *)

module KeeperWatchdog : sig
  val stale_threshold_sec : float
  val poll_sec : float
  val noop_threshold : int
  val grace_period_sec : float
  val termination_window_sec : float
  val escalation_threshold : int
  val batch_window_sec : float
  val batch_threshold : int
end

(** {1 Keeper poll intervals} *)

module KeeperPollIntervals : sig
  val crash_persistence_drain_sec : float
  val autonomous_queue_poll_sec : float
end

(** {1 Keeper runtime} *)

module KeeperRuntime : sig
  val debug : bool
  val deliberation_daily_budget_usd : unit -> float
  val snapshot_sec : int
end

(** {1 Keeper context reducer} *)

module KeeperReducer : sig
  val cap_message_tokens : int
  val cap_message_keep_recent : int
end

(** {1 Alert dedup} *)

module AlertDedup : sig
  val window_sec : float
end

(** {1 Work-as-Heartbeat (Phase 1)} *)

module WorkAsHeartbeat : sig
  val enabled : bool
  val max_silence_sec : float
end

(** {1 Smart heartbeat (Phase 2)} *)

module SmartHeartbeat : sig
  val enabled : bool
end

(** {1 Keeper keepalive loop} *)

module KeeperKeepalive : sig
  val interval_sec : int
  val max_consecutive_failures : int
  val max_consecutive_turn_failures : int
  val board_debounce_sec : float
  val sleep_chunk_sec : float
  val jitter_factor : float
  val max_idle_turns_autonomous : int
  val max_idle_turns_reactive : int
  val turn_timeout_sec : float
  val admission_wait_timeout_sec : float
  val autonomous_slot_wait_timeout_sec : float
  val oas_timeout_sec_override : float option
  val oas_max_turns_per_call : int
  val oas_max_turns_per_call_scheduled_autonomous : int

  val oas_timeout_for_estimated_input_tokens_with_turn_budget
    :  estimated_input_tokens:int
    -> max_turns:int
    -> float

  val oas_timeout_for_estimated_input_tokens : estimated_input_tokens:int -> float
  val oas_timeout_sec : float
  val stream_idle_timeout_sec : float
  val idle_skip_threshold : int
end

(** {1 gRPC heartbeat reconnect} *)

module KeeperGrpc : sig
  val max_reconnect_attempts : int
  val reconnect_backoff_sec : float
end

(** {1 Proactive generation} *)

module KeeperProactive : sig
  val max_attempts : int
  val stage_timing_ring_size : int
end

(** {1 Tool execution} *)

module KeeperToolExec : sig
  val max_consecutive_tool_failures : int
end

(** {1 Context ratio hard cap} *)

(** Absolute ceiling for compaction ratio_gate / handoff threshold
    after multiplier adjustment.  Range: [\[0.80, 0.99\]].  Reached
    qualified ([Env_config_keeper.context_ratio_hard_cap]) by
    {!Keeper_memory_recall} guard sites. *)
val context_ratio_hard_cap : float

(** {1 Context compaction (OAS)} *)

module ContextCompact : sig
  val w_recency : float
  val w_role : float
  val w_tool : float
  val role_system : float
  val role_tool : float
  val role_user : float
  val role_assistant : float
  val tool_present : float
  val tool_absent : float
  val anchor_boost : float
  val drop_importance_threshold : float
  val summarize_keep_recent : int
  val tool_output_prune_limit : int
  val dynamic_multi_agent_ratio : float
  val dynamic_focused_ratio : float
  val small_local_floor : int
  val large_cloud_floor : int
end

(** {1 Docker playground} *)

module DockerPlayground : sig
  val enabled : bool
  val container_name : string
  val container_playground_root : string
end

(** {1 Keeper sandbox (alias layer over {!Env_config_sandbox})} *)

module KeeperSandbox : sig
  val hard_mode : unit -> bool
  val docker_image : unit -> string
  val preflight_enabled : unit -> bool
  val pids_limit : unit -> int
  val nofile_limit : unit -> int
  val memory : unit -> string
  val tmpfs_size : unit -> string
  val relax_fs : unit -> bool
  val read_only_rootfs_args : unit -> string list
  val tmpfs_mount : unit -> string
  val seccomp_profile : unit -> string
  val require_rootless : unit -> bool
  val require_userns : unit -> bool
  val cleanup_enabled : unit -> bool
  val cleanup_stale_after_sec : unit -> float
  val cleanup_interval_sec : unit -> float
  val with_git_dispatch_enabled : unit -> bool
  val symmetric_read_containment : unit -> bool
  val docker_read_routing : unit -> bool
end

(** {1 Dashboard health thresholds} *)

module DashboardHealth : sig
  val ctx_critical : float
  val ctx_warn : float
  val penalty_critical : float
  val penalty_warn : float
  val runtime_warning_ctx_ratio : float
end

(** {1 Wake-time payload telemetry} *)

module KeeperTelemetry : sig
  val payload_telemetry_enabled : unit -> bool
end

(** {1 Cascade runtime overrides} *)

module KeeperCascade : sig
  val provider_allowlist : unit -> string list option
end

(** {1 Transient retry backoff} *)

module KeeperRetryBackoff : sig
  val max_transient_retries : unit -> int
  val transient_backoff_base_sec : unit -> float
  val transient_backoff_cap_sec : unit -> float
  val transient_backoff_sec : int -> float
  val degraded_retry_slot_phase_budget_sec : float
end

(** {1 Cascade attempt liveness — RFC-0022 §9 rollout flag} *)

module CascadeAttemptLiveness : sig
  type mode =
    | Off
    (** No FSM driving, no counter, no kills. Equivalent to the
            world before RFC-0022. *)
    | Observe
    (** FSM runs alongside the existing cascade attempt; would-be
            kills are logged and counted ([masc_cascade_attempt_liveness_kill_total]),
            but the cascade FSM never sees them. Default. *)
    | Enforce
    (** FSM runs and would-be kills are reported back to the
            cascade FSM as [Failed_attempt], advancing to the next
            provider. Reserved for PR-3+ once observation has produced
            calibration data per §9 Phase B. *)

  (** Read [MASC_CASCADE_ATTEMPT_LIVENESS]. Unrecognised values fall
      back to {!Observe} (with a one-time stderr warning). *)
  val mode : unit -> mode

  (** Stable string label for telemetry / log output:
      [off | observe | enforce]. *)
  val mode_label : mode -> string
end

