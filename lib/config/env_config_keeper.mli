(** Env_config_keeper — keeper runtime parameters from environment.

    All [MASC_KEEPER_*] env vars in this module can also be set
    declaratively in [<resolved config root>/runtime.toml].
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

(** {1 Keeper wire capture} *)

module KeeperWireCapture : sig
  val retention_days : unit -> int
  val max_bytes : unit -> int
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
end

(** {1 Keeper poll intervals} *)

module KeeperPollIntervals : sig
  val crash_persistence_drain_sec : float
end

(** {1 Keeper runtime} *)

module KeeperRuntime : sig
  val debug : bool
  val deliberation_daily_budget_usd : unit -> float
  val snapshot_sec : int
end

(** {1 Keeper Memory OS} *)

module KeeperMemoryOs : sig
  (** Env-var names (SSOT). The config-introspection registry and tests must
      reference these constants rather than re-spelling the literals, so a
      knob rename breaks compilation instead of silently drifting. *)

  val recall_env_key : string
  val librarian_env_key : string
  val librarian_cadence_turns_env_key : string
  val librarian_max_messages_env_key : string
  val librarian_timeout_sec_env_key : string
  val librarian_max_tokens_env_key : string
  val librarian_runtime_id_env_key : string
  val librarian_global_slot_env_key : string
  val gc_env_key : string
  val consolidation_env_key : string
  val consolidation_runtime_id_env_key : string

  val recall_enabled_default : bool
  val librarian_enabled_default : bool
  val librarian_cadence_turns_default : int
  val librarian_max_messages_default : int
  val librarian_timeout_sec_default : float
  val librarian_max_tokens_default : int
  val librarian_runtime_id_default : string option
  val librarian_global_slot_default : int
  val gc_enabled_default : bool
  val consolidation_enabled_default : bool
  val consolidation_runtime_id_default : string option

  val float_default_to_display : float -> string
  (** Render a float default for snapshot display, preserving one trailing
      decimal digit so that values like [600.] display as ["600.0"]. *)

  val recall_enabled : unit -> bool
  val librarian_enabled : unit -> bool
  val librarian_cadence_turns : unit -> int
  val librarian_max_messages : unit -> int
  val librarian_timeout_sec : unit -> float

  val librarian_max_tokens : unit -> int
  (** Output token cap for librarian extraction, applied as min with the
      provider max_tokens. Default: 4096, floored to 1. *)

  val librarian_runtime_id : unit -> string option
  val librarian_global_slot : unit -> int
  val gc_enabled : unit -> bool
  val consolidation_enabled : unit -> bool
  val consolidation_runtime_id : unit -> string option
end

(** {1 Keeper dashboard compaction snapshots} *)

module KeeperCompactionSnapshots : sig
  val default_limit : int
  val max_limit : int
  val manifest_scan_min_files : int
  val manifest_scan_limit_multiplier : int
  val manifest_tail_max_lines : int
end

(** {1 Keeper vision tool} *)

module KeeperVision : sig
  (** Raw image-byte budget for [analyze_image], clamped to [1, 10 MiB]. *)
  val max_image_bytes : unit -> int

  (** Base inter-candidate backoff, clamped to [0, 5] seconds. *)
  val candidate_backoff_base_sec : unit -> float

  (** Max inter-candidate backoff, clamped to [base, 30] seconds. *)
  val candidate_backoff_max_sec : unit -> float
end

(** {1 Keeper generated media} *)

module KeeperGeneratedMedia : sig
  (** Raw generated-media byte budget for durable store and serve, clamped to
      [1, 50 MiB]. *)
  val max_bytes : unit -> int

  (** Generated-media directory byte cap after opportunistic cleanup, clamped to
      [1, 5 GiB]. *)
  val dir_max_bytes : unit -> int

  (** Generated-media file retention age for opportunistic cleanup, clamped to
      [1 second, 30 days]. *)
  val retention_seconds : unit -> float
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

(** {1 Visibility gate (consumer-driven idle backoff)} *)

module KeeperVisibilityGate : sig
  val enabled : bool
end

(** {1 Keeper keepalive loop} *)

module KeeperKeepalive : sig
  val interval_sec : int
  val max_consecutive_failures : int
  val max_consecutive_turn_failures : int
  val sleep_chunk_sec : float
  val jitter_factor : float
  val max_idle_turns_autonomous : int
  val max_idle_turns_reactive : int
  val turn_timeout_sec : float
  val oas_timeout_sec_override : float option


  val oas_call_timeout_sec : float
  (** Resolved OAS-call timeout: [oas_timeout_sec_override] when set, otherwise
      [turn_timeout_sec]. RFC-0156: no token- or turn-budget dependence. *)
  val attempt_watchdog_safety_cap_sec : float
  (** Deprecated compatibility knob for the removed whole-run attempt watchdog.
      The keeper runtime must not apply this as a wall-clock timeout around
      active provider/tool execution. Env:
      [MASC_KEEPER_ATTEMPT_WATCHDOG_SAFETY_CAP_SEC]. *)
  val stream_idle_timeout_sec : float

  val execution_idle_timeout_sec : float option
  (** OAS Agent.run inactivity deadline. [Some s] forwards to
      [Builder.with_execution_idle_timeout] through the keeper runtime
      resolver only for paths that can prove active tool execution is excluded.
      The keeper path currently parses this knob but does not forward it.

      Env: [MASC_KEEPER_EXECUTION_IDLE_TIMEOUT_SEC]. Default: disabled.
      Clamp range when enabled: [5, 600] s. Unset, invalid, [0], or a
      negative value disables it. Kept opt-in because this is an Agent.run-level
      stall detector, not provider transport policy or tool timeout policy. *)

  val body_timeout_sec_override : float option
  (** Total HTTP body-consumption deadline for non-streaming OAS completion
      calls. [None] (env unset) leaves the runtime builder wire untouched.
      [Some s] forwards to [Builder.with_body_timeout] for sync completion
      paths. Streaming paths ignore it and rely on {!stream_idle_timeout_sec}
      plus attempt liveness observation.

      Env: [MASC_KEEPER_BODY_TIMEOUT_SEC]. Clamp range: [10, 600] s. *)

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

(** {1 Runtime Saturation Signal (RFC-0153 Phase A.2)} *)

module RuntimeSaturationSignal : sig
  val enabled : unit -> bool
  (** [MASC_RUNTIME_SATURATION_SIGNAL_ENABLED] flag. Default false.

      When true, {!Runtime_attempt_fsm} emits a Otel_metric_store counter
      ([masc_keeper_runtime_saturation_signal_total]) with a typed
      [kind] label whenever a saturation event matching
      {!Runtime_saturation_signal.t} is observed. Used to feed
      Phase B (tier admission semaphore) and Phase C (adaptive
      throttling) without altering any existing wire format,
      string label, or control-flow path. *)
end


(** {1 Transient retry backoff} *)

module KeeperRetryBackoff : sig
  val max_transient_retries : unit -> int
  val transient_backoff_base_sec : unit -> float
  val transient_backoff_cap_sec : unit -> float
  val transient_backoff_sec : int -> float
  val degraded_retry_slot_phase_budget_sec : float
end
